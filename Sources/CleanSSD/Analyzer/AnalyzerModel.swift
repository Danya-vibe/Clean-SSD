import SwiftUI

@MainActor
final class AnalyzerModel: ObservableObject {
    @Published private(set) var root: FileNode?
    @Published private(set) var focus: FileNode?
    @Published private(set) var segments: [SunSegment] = []
    @Published var selected: FileNode?
    @Published private(set) var isScanning = false
    @Published private(set) var scannedFiles = 0
    @Published private(set) var scannedBytes: Int64 = 0
    @Published private(set) var currentPath = ""
    @Published private(set) var deniedCount = 0
    @Published private(set) var rootTitle = ""
    @Published private(set) var scanDuration: TimeInterval = 0
    @Published private(set) var hiddenSpace: Int64?
    @Published private(set) var collector: [FileNode] = []
    @Published private(set) var isDeleting = false
    @Published private(set) var revision = 0
    @Published var alertMessage: String?

    private var progress: ScanProgress?
    private var scanStart = Date()

    static var homePath: String { NSHomeDirectory() }
    static var dataVolumePath: String {
        FSUtil.isDirectory("/System/Volumes/Data/Users") ? "/System/Volumes/Data" : "/"
    }

    // MARK: Сканирование

    func scan(path: String, title: String) {
        progress?.cancel()
        let progress = ScanProgress()
        self.progress = progress
        root = nil
        focus = nil
        segments = []
        selected = nil
        collector = []
        hiddenSpace = nil
        scannedFiles = 0
        scannedBytes = 0
        deniedCount = 0
        currentPath = path
        rootTitle = title
        isScanning = true
        scanStart = Date()

        Task.detached(priority: .userInitiated) {
            let node = DiskScanner.scan(root: path, progress: progress)
            await self.finishScan(node, progress: progress, path: path)
        }
        Task {
            while isScanning, self.progress === progress {
                let snapshot = progress.snapshot()
                scannedFiles = snapshot.files
                scannedBytes = snapshot.bytes
                deniedCount = snapshot.denied
                if !snapshot.current.isEmpty { currentPath = snapshot.current }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    func cancelScan() {
        progress?.cancel()
        progress = nil
        isScanning = false
    }

    private func finishScan(_ node: FileNode, progress: ScanProgress, path: String) {
        guard self.progress === progress, !progress.isCancelled else { return }
        let snapshot = progress.snapshot()
        scannedFiles = snapshot.files
        scannedBytes = snapshot.bytes
        deniedCount = snapshot.denied
        scanDuration = Date().timeIntervalSince(scanStart)
        isScanning = false
        root = node
        if path == Self.dataVolumePath, let volume = VolumeInfo.current() {
            hiddenSpace = max(0, volume.usedIncludingPurgeable - node.size)
        }
        setFocus(node)
    }

    // MARK: Навигация

    func setFocus(_ node: FileNode) {
        guard node.isDirectory else { return }
        focus = node
        selected = nil
        rebuild()
    }

    func goUp() {
        if let parent = focus?.parent { setFocus(parent) }
    }

    private func rebuild() {
        segments = focus.map(SunburstLayout.build) ?? []
        revision += 1
    }

    func node(atPath path: String) -> FileNode? {
        root?.find(path: path)
    }

    // MARK: Коллектор

    func addToCollector(_ node: FileNode) {
        guard node.parent != nil else { return }
        if collector.contains(where: { $0 === node || $0.isAncestor(of: node) }) { return }
        collector.removeAll { node.isAncestor(of: $0) }
        collector.append(node)
    }

    func removeFromCollector(_ node: FileNode) {
        collector.removeAll { $0 === node }
    }

    func clearCollector() {
        collector.removeAll()
    }

    var collectorSize: Int64 { collector.reduce(0) { $0 + $1.size } }

    func deleteCollected(toTrash: Bool) {
        let nodes = collector
        let paths = nodes.map(\.path)
        guard !paths.isEmpty else { return }
        isDeleting = true
        Task.detached(priority: .userInitiated) {
            var results: [String?] = []
            let fm = FileManager.default
            for path in paths {
                guard SafetyGuard.canDeleteUserSelected(path) else {
                    results.append("\((path as NSString).lastPathComponent): системный путь защищён")
                    continue
                }
                do {
                    if toTrash {
                        try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    } else {
                        try fm.removeItem(atPath: path)
                    }
                    results.append(nil)
                } catch {
                    results.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }
            let outcome = results
            await MainActor.run { self.applyDeletion(nodes: nodes, errors: outcome, toTrash: toTrash) }
        }
    }

    private func applyDeletion(nodes: [FileNode], errors: [String?], toTrash: Bool) {
        var freed: Int64 = 0
        var newFocus = focus
        for (node, error) in zip(nodes, errors) where error == nil {
            if let current = newFocus, current === node || node.isAncestor(of: current) {
                newFocus = node.parent
            }
            freed += node.size
            node.removeFromParent()
        }
        collector.removeAll { node in
            zip(nodes, errors).contains { $0.0 === node && $0.1 == nil }
        }
        isDeleting = false
        if let newFocus { setFocus(newFocus) } else { rebuild() }

        let failures = errors.compactMap { $0 }
        var message = (toTrash ? "Перемещено в Корзину: " : "Удалено: ") + Fmt.bytes(freed)
        if !failures.isEmpty {
            message += "\n\nНе удалось удалить:\n" + failures.prefix(8).joined(separator: "\n")
        }
        alertMessage = message
    }
}
