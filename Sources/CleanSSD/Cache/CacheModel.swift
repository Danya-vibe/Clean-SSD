import SwiftUI

struct CacheItem: Identifiable {
    let target: CacheTarget
    var size: Int64
    var fileCount: Int
    var accessDenied: Bool
    var isRunning: Bool
    var isSelected: Bool

    var id: String { target.id }
}

struct CleanReport: Identifiable {
    let id = UUID()
    let freed: Int64
    let movedToTrash: Bool
    let failedCount: Int
    let adminError: String?
}

@MainActor
final class CacheModel: ObservableObject {
    @Published private(set) var items: [CacheItem] = []
    @Published private(set) var lockedCategories: Set<CacheCategory> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var hasFullDiskAccess = Permissions.hasFullDiskAccess
    @Published var report: CleanReport?
    @Published var expanded: Set<CacheCategory> = [.system, .user, .browsers]

    var categories: [CacheCategory] {
        CacheCategory.allCases.filter { category in
            items.contains { $0.target.category == category } || lockedCategories.contains(category)
        }
    }

    func items(in category: CacheCategory) -> [CacheItem] {
        items.filter { $0.target.category == category }
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedItems: [CacheItem] { items.filter(\.isSelected) }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func refreshPermissions() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess
    }

    func scan() {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        refreshPermissions()
        let fda = hasFullDiskAccess
        let running = RunningApps.snapshot()
        Task.detached(priority: .userInitiated) {
            let found = CacheDiscovery.discover(hasFDA: fda)
            let sizes = CacheMeasure.measureAll(found.targets)
            var items: [CacheItem] = []
            for (target, size) in zip(found.targets, sizes) where size.bytes >= 4096 || size.denied {
                let isRunning = running.isRunning(bundleID: target.bundleID, processName: target.processName)
                items.append(CacheItem(target: target, size: size.bytes, fileCount: size.files,
                                       accessDenied: size.denied && size.bytes == 0, isRunning: isRunning,
                                       isSelected: Self.defaultSelection(target, running: isRunning, size: size)))
            }
            items.sort { $0.size > $1.size }
            let locked = found.locked
            let result = items
            await MainActor.run {
                self.items = result
                self.lockedCategories = locked
                self.isScanning = false
                self.hasScanned = true
            }
        }
    }

    nonisolated private static func defaultSelection(_ target: CacheTarget, running: Bool, size: CacheMeasure.Result) -> Bool {
        target.safety == .safe && !running && size.bytes > 0 && target.category != .trash
    }

    // MARK: Выбор

    func toggle(_ item: CacheItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isSelected.toggle()
    }

    func selectionState(of category: CacheCategory) -> CheckState {
        let group = items(in: category)
        let selected = group.filter(\.isSelected).count
        if selected == 0 { return .off }
        return selected == group.count ? .on : .mixed
    }

    func setSelection(_ value: Bool, in category: CacheCategory) {
        for index in items.indices where items[index].target.category == category {
            items[index].isSelected = value
        }
    }

    func selectAllSafe() {
        for index in items.indices {
            items[index].isSelected = items[index].target.safety == .safe && !items[index].isRunning
                && items[index].target.category != .trash
        }
    }

    func deselectAll() {
        for index in items.indices { items[index].isSelected = false }
    }

    // MARK: Очистка

    func cleanSelected(moveToTrash: Bool) {
        let selected = selectedItems
        guard !selected.isEmpty, !isCleaning else { return }
        isCleaning = true
        Task.detached(priority: .userInitiated) {
            let before = selected.reduce(Int64(0)) { $0 + $1.size }
            let userTargets = selected.filter { !$0.target.requiresAdmin }.map(\.target)
            let adminTargets = selected.filter { $0.target.requiresAdmin }.map(\.target)

            var outcome = CacheCleaner.cleanUserTargets(userTargets, moveToTrash: moveToTrash)
            if !adminTargets.isEmpty {
                let adminOutcome = CacheCleaner.cleanAdminTargets(adminTargets)
                outcome.failed += adminOutcome.failed
                outcome.adminError = adminOutcome.adminError
            }

            let after = CacheMeasure.measureAll(selected.map(\.target))
            let remaining = after.reduce(Int64(0)) { $0 + $1.bytes }
            var updated: [String: CacheMeasure.Result] = [:]
            for (item, size) in zip(selected, after) { updated[item.id] = size }

            let report = CleanReport(freed: max(0, before - remaining), movedToTrash: moveToTrash,
                                     failedCount: outcome.failed.count, adminError: outcome.adminError)
            let sizes = updated
            await MainActor.run {
                self.items = self.items.compactMap { item in
                    guard let size = sizes[item.id] else { return item }
                    guard size.bytes >= 4096 else { return nil }
                    var copy = item
                    copy.size = size.bytes
                    copy.fileCount = size.files
                    copy.isSelected = false
                    return copy
                }
                self.isCleaning = false
                self.report = report
            }
        }
    }
}

enum CheckState {
    case on, off, mixed
}
