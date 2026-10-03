import Foundation

/// Режим только для чтения: `CleanSSD --report [--scan <путь>]`.
/// Ничего не удаляет — печатает найденный кэш и (опционально) самые большие папки.
enum CLIReport {
    static func run(arguments: [String]) {
        let fda = Permissions.hasFullDiskAccess
        print("Полный доступ к диску: \(fda ? "да" : "нет")")
        let start = Date()
        let found = CacheDiscovery.discover(hasFDA: fda)
        let discovered = Date()
        let sizes = CacheMeasure.measureAll(found.targets)
        print(String(format: "Поиск: %.1f с, подсчёт размеров: %.1f с", discovered.timeIntervalSince(start), Date().timeIntervalSince(discovered)))
        let running = RunningApps.snapshot()
        var total: Int64 = 0
        for category in CacheCategory.allCases {
            let rows = zip(found.targets, sizes)
                .filter { $0.0.category == category && ($0.1.bytes >= 4096 || $0.1.denied) }
                .sorted { $0.1.bytes > $1.1.bytes }
            let locked = found.locked.contains(category)
            guard !rows.isEmpty || locked else { continue }
            let sum = rows.reduce(Int64(0)) { $0 + $1.1.bytes }
            total += sum
            print("\n== \(category.title): \(Fmt.bytes(sum))\(locked ? "  [частично недоступно]" : "")")
            for (target, size) in rows.prefix(12) {
                var flags: [String] = []
                if target.safety == .review { flags.append("проверьте") }
                if target.requiresAdmin { flags.append("админ") }
                if size.denied { flags.append("нет доступа") }
                if running.isRunning(bundleID: target.bundleID, processName: target.processName) { flags.append("запущено") }
                let flagText = flags.isEmpty ? "" : "  [" + flags.joined(separator: ", ") + "]"
                print(String(format: "  %10@  %@%@", Fmt.bytes(size.bytes) as NSString, target.title as NSString, flagText as NSString))
            }
            if rows.count > 12 { print("  … ещё \(rows.count - 12)") }
        }
        print("\nВсего: \(Fmt.bytes(total)), \(found.targets.count) мест, \(String(format: "%.1f", Date().timeIntervalSince(start))) с")

        if let index = arguments.firstIndex(of: "--scan"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            let scanStart = Date()
            let progress = ScanProgress()
            let root = DiskScanner.scan(root: path, progress: progress)
            let snap = progress.snapshot()
            print("\nСканирование \(path): \(Fmt.bytes(root.size)), \(Fmt.count(snap.files)) файлов, нет доступа: \(snap.denied), \(String(format: "%.1f", Date().timeIntervalSince(scanStart))) с")
            for child in root.children.prefix(15) {
                print(String(format: "  %10@  %@", Fmt.bytes(child.size) as NSString, child.name as NSString))
            }
        }
    }

    /// `CleanSSD --storage` — разбивка диска по категориям «Хранилища» (только чтение).
    static func storage() {
        let start = Date()
        var total: Int64 = 0
        for category in StorageCategory.allCases where category != .systemData {
            var bytes: Int64 = 0
            if category == .macOS {
                bytes = APFSVolumes.systemVolumes().reduce(0) { $0 + $1.used }
            } else {
                let roots = StorageLayout.roots(for: category)
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: roots.count) { index in
                    let size = DiskScanner.usage(of: roots[index]).bytes
                    lock.lock(); bytes += size; lock.unlock()
                }
            }
            total += bytes
            print(String(format: "%12@  %@", Fmt.bytes(bytes) as NSString, category.title as NSString))
        }
        if let volume = VolumeInfo.current() {
            let used = volume.total - max(volume.available, volume.availableForImportant)
            print(String(format: "%12@  %@", Fmt.bytes(max(0, used - total)) as NSString, "Системные данные" as NSString))
            print("Используется \(Fmt.bytes(used)) из \(Fmt.bytes(volume.total)), \(String(format: "%.0f", Date().timeIntervalSince(start))) с")
        }
    }
}
