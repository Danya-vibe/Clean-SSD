import Foundation

enum CacheMeasure {
    struct Result {
        var bytes: Int64 = 0
        var files = 0
        var denied = false
    }

    static func measure(_ target: CacheTarget) -> Result {
        var result = Result()
        for path in target.paths {
            let parts: [String]
            if case .contentsOlderThan(let days) = target.mode {
                guard let old = FSUtil.children(of: path, olderThanDays: days) else {
                    result.denied = true
                    continue
                }
                parts = old
            } else {
                parts = [path]
            }
            for part in parts {
                let usage = DiskScanner.usage(of: part)
                result.bytes += usage.bytes
                result.files += usage.files
                result.denied = result.denied || usage.denied
            }
        }
        return result
    }

    static func measureAll(_ targets: [CacheTarget]) -> [Result] {
        var results = [Result](repeating: Result(), count: targets.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            let result = measure(targets[index])
            lock.lock()
            results[index] = result
            lock.unlock()
        }
        return results
    }
}

enum CacheCleaner {
    struct Outcome {
        var failed: [String] = []
        var adminError: String?
    }

    /// Очистка мест, доступных пользователю. Корзину всегда очищаем безвозвратно.
    static func cleanUserTargets(_ targets: [CacheTarget], moveToTrash: Bool) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        for target in targets {
            let useTrash = moveToTrash && target.category != .trash
            for path in target.paths {
                guard SafetyGuard.canClean(path, admin: false) else {
                    outcome.failed.append(path)
                    continue
                }
                let victims: [String]
                switch target.mode {
                case .wholeItem:
                    victims = [path]
                case .contents:
                    victims = FSUtil.children(of: path) ?? []
                case .contentsOlderThan(let days):
                    victims = FSUtil.children(of: path, olderThanDays: days) ?? []
                }
                for victim in victims {
                    do {
                        if useTrash {
                            try fm.trashItem(at: URL(fileURLWithPath: victim), resultingItemURL: nil)
                        } else {
                            try fm.removeItem(atPath: victim)
                        }
                    } catch {
                        outcome.failed.append(victim)
                    }
                }
            }
        }
        return outcome
    }

    /// Очистка системных мест (/Library/Caches, /Library/Logs) одним запросом пароля.
    static func cleanAdminTargets(_ targets: [CacheTarget]) -> Outcome {
        var outcome = Outcome()
        var commands: [String] = []
        for target in targets {
            for path in target.paths {
                guard SafetyGuard.canClean(path, admin: true) else {
                    outcome.failed.append(path)
                    continue
                }
                let quoted = Privileged.shellQuote(path)
                switch target.mode {
                case .wholeItem:
                    commands.append("/bin/rm -rf \(quoted) 2>/dev/null")
                case .contents, .contentsOlderThan:
                    commands.append("/usr/bin/find \(quoted) -mindepth 1 -maxdepth 1 -exec /bin/rm -rf {} + 2>/dev/null")
                }
            }
        }
        guard !commands.isEmpty else { return outcome }
        // Защищённые SIP файлы удалить нельзя — это нормально, продолжаем.
        let script = commands.map { "\($0) || true" }.joined(separator: "; ")
        let result = Privileged.run(script)
        if !result.ok {
            outcome.adminError = result.message.contains("-128")
                ? "Ввод пароля администратора отменён — системный кэш не очищен."
                : "Ошибка очистки системного кэша: \(result.message)"
        }
        return outcome
    }
}
