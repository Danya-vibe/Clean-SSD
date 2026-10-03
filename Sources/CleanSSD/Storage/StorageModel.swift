import SwiftUI

struct StorageEntry: Identifiable, Hashable {
    let path: String
    let size: Int64
    let isDirectory: Bool

    var id: String { path }
    var name: String {
        let name = FileManager.default.displayName(atPath: path)
        return name.isEmpty ? (path as NSString).lastPathComponent : name
    }
}

struct StorageDetail {
    var entries: [StorageEntry] = []
    var largeFiles: [StorageEntry] = []
    var denied = false
}

@MainActor
final class StorageModel: ObservableObject {
    @Published private(set) var volume = VolumeInfo.current()
    @Published private(set) var sizes: [StorageCategory: Int64] = [:]
    @Published private(set) var partial: Set<StorageCategory> = []
    @Published private(set) var pending: Set<StorageCategory> = []
    @Published private(set) var macOSVolumes: [APFSVolumes.Volume] = []
    @Published private(set) var snapshots: [String] = []
    @Published private(set) var autoEmptyTrash = StorageModel.readAutoEmptyTrash()
    @Published private(set) var hasScanned = false
    private var generation = 0

    var isScanning: Bool { !pending.isEmpty }

    /// Занято так же, как считает macOS: всё, кроме свободного и освобождаемого места.
    var used: Int64 {
        guard let volume else { return 0 }
        return volume.total - max(volume.available, volume.availableForImportant)
    }

    var free: Int64 {
        guard let volume else { return 0 }
        return max(volume.available, volume.availableForImportant)
    }

    func size(of category: StorageCategory) -> Int64? {
        if category == .systemData {
            guard pending.isEmpty, hasScanned else { return nil }
            let others = StorageCategory.allCases.filter { $0 != .systemData }.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            return max(0, used - others)
        }
        if pending.contains(category) { return nil }
        return sizes[category]
    }

    // MARK: Сканирование

    func refresh() {
        generation += 1
        let token = generation
        volume = VolumeInfo.current()
        autoEmptyTrash = Self.readAutoEmptyTrash()
        sizes = [:]
        partial = []
        pending = Set(StorageCategory.allCases)
        hasScanned = true

        Task.detached(priority: .userInitiated) {
            let volumes = APFSVolumes.systemVolumes()
            let snapshots = LocalSnapshots.list()
            await MainActor.run {
                guard token == self.generation else { return }
                self.macOSVolumes = volumes
                self.sizes[.macOS] = volumes.reduce(0) { $0 + $1.used }
                self.snapshots = snapshots
                self.pending.remove(.macOS)
                self.settle()
            }
        }

        Task.detached(priority: .userInitiated) {
            // Разбиваем крупные корни на детей, чтобы считать параллельно.
            var jobs: [(StorageCategory, String)] = []
            for category in StorageCategory.allCases {
                for root in StorageLayout.roots(for: category) {
                    if FSUtil.isDirectory(root), !root.hasSuffix(".photoslibrary"), let children = FSUtil.children(of: root) {
                        jobs += children.map { (category, $0) }
                    } else {
                        jobs.append((category, root))
                    }
                }
            }
            var remaining: [StorageCategory: Int] = [:]
            for (category, _) in jobs { remaining[category, default: 0] += 1 }
            let empty = Set(StorageCategory.allCases).subtracting(remaining.keys).subtracting([.macOS])
            let counts = remaining
            await MainActor.run {
                guard token == self.generation else { return }
                for category in empty where category != .systemData { self.sizes[category] = 0 }
                self.pending.subtract(empty.subtracting([.systemData]))
                self.remaining = counts
                self.settle()
            }

            let work = jobs
            DispatchQueue.concurrentPerform(iterations: work.count) { index in
                let (category, path) = work[index]
                let usage = DiskScanner.usage(of: path)
                Task { @MainActor in
                    self.accumulate(category, bytes: usage.bytes, denied: usage.denied, token: token)
                }
            }
        }
    }

    private var remaining: [StorageCategory: Int] = [:]

    private func accumulate(_ category: StorageCategory, bytes: Int64, denied: Bool, token: Int) {
        guard token == generation else { return }
        sizes[category, default: 0] += bytes
        if denied { partial.insert(category) }
        remaining[category, default: 1] -= 1
        if remaining[category] == 0 { pending.remove(category) }
        settle()
    }

    /// «Системные данные» считаются как остаток, когда готово всё остальное.
    private func settle() {
        if pending == [.systemData] { pending.remove(.systemData) }
    }

    // MARK: Подробности

    func loadDetail(for category: StorageCategory) async -> StorageDetail {
        await Task.detached(priority: .userInitiated) { StorageScanner.computeDetail(for: category) }.value
    }

    /// Составляющие «Системных данных», которые можно измерить без прав администратора.
    func systemDataComponents() async -> [StorageEntry] {
        let home = NSHomeDirectory()
        var paths = [home + "/Library/Caches", "/Library/Caches", home + "/Library/Logs", "/Library/Logs",
                     "/private/var/vm", "/Library"]
        if let userTemp = FSUtil.confstrPath(_CS_DARWIN_USER_TEMP_DIR) {
            paths.append((userTemp as NSString).deletingLastPathComponent)
        }
        let list = paths
        return await Task.detached(priority: .userInitiated) { StorageScanner.measureComponents(list) }.value
    }

    // MARK: Действия

    func moveToTrash(_ entry: StorageEntry, category: StorageCategory) throws {
        guard SafetyGuard.canDeleteUserSelected(entry.path) else {
            throw NSError(domain: "CleanSSD", code: 1, userInfo: [NSLocalizedDescriptionKey: "Этот путь защищён"])
        }
        try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
        sizes[category] = max(0, (sizes[category] ?? 0) - entry.size)
        if category != .trash { sizes[.trash, default: 0] += entry.size }
    }

    func setAutoEmptyTrash(_ value: Bool) {
        CFPreferencesSetAppValue("FXRemoveOldTrashItems" as CFString, value as CFBoolean, "com.apple.finder" as CFString)
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        autoEmptyTrash = Self.readAutoEmptyTrash()
    }

    nonisolated static func readAutoEmptyTrash() -> Bool {
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        return (CFPreferencesCopyAppValue("FXRemoveOldTrashItems" as CFString, "com.apple.finder" as CFString) as? Bool) ?? false
    }

    func deleteSnapshots() async -> String? {
        let list = snapshots
        let result = await Task.detached { LocalSnapshots.delete(list) }.value
        snapshots = await Task.detached { LocalSnapshots.list() }.value
        volume = VolumeInfo.current()
        return result.ok ? nil : result.message
    }
}

enum StorageScanner {
    static func computeDetail(for category: StorageCategory) -> StorageDetail {
        var paths: [String] = []
        for root in StorageLayout.roots(for: category) {
            if StorageLayout.expandsChildren(root, in: category), let children = FSUtil.children(of: root) {
                paths += children
            } else if FSUtil.exists(root) {
                paths.append(root)
            }
        }
        var entries = [StorageEntry?](repeating: nil, count: paths.count)
        var large: [StorageEntry] = []
        var denied = false
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            let path = paths[index]
            var found: [StorageEntry] = []
            let usage = DiskScanner.usage(of: path, largeFileThreshold: 100 * 1024 * 1024) { file, size in
                found.append(StorageEntry(path: file, size: size, isDirectory: false))
            }
            lock.lock()
            entries[index] = StorageEntry(path: path, size: usage.bytes, isDirectory: FSUtil.isDirectory(path))
            large += found
            denied = denied || usage.denied
            lock.unlock()
        }
        var detail = StorageDetail()
        detail.entries = entries.compactMap { $0 }.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        detail.largeFiles = Array(large.sorted { $0.size > $1.size }.prefix(200))
        detail.denied = denied
        return detail
    }

    static func measureComponents(_ list: [String]) -> [StorageEntry] {
        var result = [StorageEntry?](repeating: nil, count: list.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: list.count) { index in
            var bytes = DiskScanner.usage(of: list[index]).bytes
            // /Library включает /Library/Caches и /Library/Logs — не считаем их дважды.
            if list[index] == "/Library" {
                bytes -= DiskScanner.usage(of: "/Library/Caches").bytes + DiskScanner.usage(of: "/Library/Logs").bytes
            }
            lock.lock()
            result[index] = StorageEntry(path: list[index], size: max(0, bytes), isDirectory: true)
            lock.unlock()
        }
        return result.compactMap { $0 }.sorted { $0.size > $1.size }
    }
}
