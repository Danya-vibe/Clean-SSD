import Foundation
import Darwin

/// Потокобезопасный счётчик прогресса сканирования.
final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    private var bytes: Int64 = 0
    private var current = ""
    private var denied = 0
    private var cancelled = false

    func add(files f: Int, bytes b: Int64, current c: String?) {
        lock.lock()
        files += f
        bytes += b
        if let c { current = c }
        lock.unlock()
    }

    func addDenied() {
        lock.lock(); denied += 1; lock.unlock()
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func snapshot() -> (files: Int, bytes: Int64, current: String, denied: Int) {
        lock.lock(); defer { lock.unlock() }
        return (files, bytes, current, denied)
    }
}

/// Учитывает жёсткие ссылки, чтобы не считать один и тот же файл дважды.
final class HardlinkRegistry: @unchecked Sendable {
    private struct Key: Hashable {
        let dev: Int32
        let ino: UInt64
    }
    private var seen = Set<Key>()
    private let lock = NSLock()

    func firstSighting(dev: Int32, ino: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.insert(Key(dev: dev, ino: ino)).inserted
    }
}

enum DiskScanner {
    /// Файлы меньше порога не хранятся отдельными узлами.
    static let smallFileThreshold: Int64 = 128 * 1024

    /// Параллельно сканирует дерево. Верхние два уровня раскрываются вручную,
    /// а поддеревья обходятся через fts(3) в пуле потоков. Не выходит за пределы тома.
    static func scan(root: String, progress: ScanProgress) -> FileNode {
        let rootPath = root == "/" ? "/" : (root as NSString).standardizingPath
        let rootNode = FileNode(name: rootPath, isDirectory: true)
        var st = stat()
        guard lstat(rootPath, &st) == 0 else {
            rootNode.isAccessDenied = true
            return rootNode
        }
        let links = HardlinkRegistry()
        var jobs: [(FileNode, String)] = []
        expand(node: rootNode, path: rootPath, dev: st.st_dev, level: 0, splitDepth: 2,
               links: links, progress: progress, jobs: &jobs)

        let work = jobs
        DispatchQueue.concurrentPerform(iterations: work.count) { index in
            guard !progress.isCancelled else { return }
            let (node, path) = work[index]
            fill(node: node, path: path, links: links, progress: progress)
        }
        rootNode.finalize()
        return rootNode
    }

    private static func expand(node: FileNode, path: String, dev: dev_t, level: Int, splitDepth: Int,
                               links: HardlinkRegistry, progress: ScanProgress,
                               jobs: inout [(FileNode, String)]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            node.isAccessDenied = true
            progress.addDenied()
            return
        }
        var st = stat()
        if lstat(path, &st) == 0 { node.selfSize += Int64(st.st_blocks) * 512 }
        for name in names {
            let childPath = path == "/" ? "/" + name : path + "/" + name
            guard lstat(childPath, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                // Точки монтирования других томов пропускаем.
                guard st.st_dev == dev else { continue }
                let child = FileNode(name: name, isDirectory: true)
                node.append(child)
                if level + 1 < splitDepth {
                    expand(node: child, path: childPath, dev: dev, level: level + 1, splitDepth: splitDepth,
                           links: links, progress: progress, jobs: &jobs)
                } else {
                    jobs.append((child, childPath))
                }
            } else {
                let size = addFile(to: node, name: name, info: st, links: links)
                progress.add(files: 1, bytes: size, current: nil)
            }
        }
    }

    @discardableResult
    private static func addFile(to parent: FileNode, name: @autoclosure () -> String, info: stat,
                                links: HardlinkRegistry) -> Int64 {
        if info.st_nlink > 1 && !links.firstSighting(dev: info.st_dev, ino: info.st_ino) { return 0 }
        let size = Int64(info.st_blocks) * 512
        if size >= smallFileThreshold {
            let file = FileNode(name: name(), isDirectory: false)
            file.selfSize = size
            parent.append(file)
        } else {
            parent.smallFilesCount += 1
            parent.smallFilesSize += size
        }
        return size
    }

    private static func entryName(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
        if let offset = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name) {
            let raw = UnsafeRawPointer(entry).advanced(by: offset).assumingMemoryBound(to: CChar.self)
            return String(cString: raw)
        }
        return (String(cString: entry.pointee.fts_path) as NSString).lastPathComponent
    }

    private static func fill(node: FileNode, path: String, links: HardlinkRegistry, progress: ScanProgress) {
        guard let cPath = strdup(path) else { return }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(fts) }

        var stack: [FileNode] = []
        var pendingFiles = 0
        var pendingBytes: Int64 = 0
        var counter = 0

        while let entry = fts_read(fts) {
            counter += 1
            if counter & 0x3FF == 0 {
                progress.add(files: pendingFiles, bytes: pendingBytes, current: String(cString: entry.pointee.fts_path))
                pendingFiles = 0
                pendingBytes = 0
                if progress.isCancelled { break }
            }
            let level = Int(entry.pointee.fts_level)
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                let blocks = Int64(entry.pointee.fts_statp.pointee.st_blocks) * 512
                if level == 0 {
                    node.selfSize += blocks
                    stack.append(node)
                } else {
                    let child = FileNode(name: entryName(entry), isDirectory: true)
                    child.selfSize = blocks
                    (stack.last ?? node).append(child)
                    stack.append(child)
                }
            case FTS_DP:
                if stack.count > level { stack.removeLast() }
            case FTS_DNR, FTS_ERR:
                // Каталог не удалось прочитать: fts возвращает его повторно вместо FTS_DP.
                progress.addDenied()
                if stack.count > level {
                    stack.removeLast().isAccessDenied = true
                } else if Int32(entry.pointee.fts_info) == FTS_DNR {
                    let child = FileNode(name: entryName(entry), isDirectory: true)
                    child.isAccessDenied = true
                    (stack.last ?? node).append(child)
                }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let statp = entry.pointee.fts_statp else { break }
                let size = addFile(to: stack.last ?? node, name: entryName(entry), info: statp.pointee, links: links)
                pendingFiles += 1
                pendingBytes += size
            case FTS_NS:
                progress.addDenied()
            default:
                break
            }
        }
        progress.add(files: pendingFiles, bytes: pendingBytes, current: nil)
    }

    /// Быстрый аналог `du` без построения дерева.
    /// `onLargeFile` вызывается для каждого файла размером от `largeFileThreshold`.
    static func usage(of path: String, largeFileThreshold: Int64 = .max,
                      onLargeFile: ((String, Int64) -> Void)? = nil) -> (bytes: Int64, files: Int, denied: Bool) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return (0, 0, errno == EACCES || errno == EPERM) }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            let size = Int64(st.st_blocks) * 512
            if size >= largeFileThreshold { onLargeFile?(path, size) }
            return (size, 1, false)
        }

        guard let cPath = strdup(path) else { return (0, 0, false) }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return (0, 0, true) }
        defer { fts_close(fts) }

        var bytes: Int64 = 0
        var files = 0
        var denied = false
        var seen = Set<UInt64>()
        while let entry = fts_read(fts) {
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                bytes += Int64(entry.pointee.fts_statp.pointee.st_blocks) * 512
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let statp = entry.pointee.fts_statp else { break }
                let info = statp.pointee
                if info.st_nlink > 1 && !seen.insert(info.st_ino).inserted { break }
                let size = Int64(info.st_blocks) * 512
                bytes += size
                files += 1
                if size >= largeFileThreshold, let onLargeFile {
                    onLargeFile(String(cString: entry.pointee.fts_path), size)
                }
            case FTS_DNR, FTS_ERR, FTS_NS:
                denied = true
            default:
                break
            }
        }
        return (bytes, files, denied)
    }
}
