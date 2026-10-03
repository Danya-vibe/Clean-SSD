import AppKit
import Darwin

enum Fmt {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, value))
    }

    static func count(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

// MARK: - Файловая система

enum FSUtil {
    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Полные пути детей каталога (включая скрытые) или nil, если нет доступа.
    static func children(of path: String) -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return names.filter { $0 != ".DS_Store" }.map { (path as NSString).appendingPathComponent($0) }
    }

    static func children(of path: String, olderThanDays days: Int) -> [String]? {
        guard let all = children(of: path) else { return nil }
        let cutoff = Int(Date().timeIntervalSince1970) - days * 86_400
        return all.filter { child in
            var st = stat()
            guard lstat(child, &st) == 0 else { return false }
            return Int(st.st_mtimespec.tv_sec) < cutoff
        }
    }

    static func confstrPath(_ name: Int32) -> String? {
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        confstr(name, &buffer, length)
        let path = String(cString: buffer)
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

// MARK: - Защита от удаления важного

enum SafetyGuard {
    static let home = NSHomeDirectory()

    private static let forbidden: Set<String> = {
        let roots = ["/", "/System", "/Library", "/Users", "/Applications", "/private", "/private/var", "/var",
                     "/usr", "/bin", "/sbin", "/etc", "/opt", "/Volumes", "/cores"]
        let user = ["", "/Library", "/Library/Caches", "/Library/Logs", "/Library/Application Support",
                    "/Library/Containers", "/Library/Group Containers", "/Documents", "/Desktop", "/Downloads",
                    "/Pictures", "/Movies", "/Music", "/Applications", "/.Trash"].map { home + $0 }
        var all = Set(roots + user + ["/Library/Caches", "/Library/Logs"])
        for path in Array(all) where path != "/" { all.insert("/System/Volumes/Data" + path) }
        all.insert("/System/Volumes/Data")
        return all
    }()

    private static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func isBasicSafe(_ p: String) -> Bool {
        guard p.hasPrefix("/"), !forbidden.contains(p), !FSUtil.isSymlink(p) else { return false }
        return p.split(separator: "/").count >= 3
    }

    /// Разрешено ли удалять содержимое/сам объект, найденный правилами очистки кэша.
    static func canClean(_ path: String, admin: Bool) -> Bool {
        let p = normalized(path)
        guard isBasicSafe(p) else { return false }
        if admin { return p.hasPrefix("/Library/Caches/") || p.hasPrefix("/Library/Logs/") }
        return p.hasPrefix(home + "/") || p.hasPrefix("/private/var/folders/") || p.hasPrefix("/var/folders/")
    }

    /// Разрешено ли удалять объект, выбранный пользователем в анализаторе диска.
    static func canDeleteUserSelected(_ path: String) -> Bool {
        let p = normalized(path)
        guard isBasicSafe(p) else { return false }
        // Путь через Data-том приводим к «логическому» виду: /System/Volumes/Data/Users/... → /Users/...
        let dataPrefix = "/System/Volumes/Data"
        let logical = p.hasPrefix(dataPrefix + "/") ? String(p.dropFirst(dataPrefix.count)) : p
        let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/private/var/db/", "/private/var/vm/",
                              "/Library/Apple/"]
        return !systemPrefixes.contains { logical.hasPrefix($0) }
    }
}

// MARK: - Запуск с правами администратора

enum Privileged {
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Выполняет команду через стандартный системный диалог запроса пароля администратора.
    static func run(_ command: String) -> (ok: Bool, message: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        return Shell.run("/usr/bin/osascript", ["-e", source])
    }
}

enum Shell {
    static func run(_ executable: String, _ arguments: [String]) -> (ok: Bool, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: process.terminationStatus == 0 ? output : errors, as: UTF8.self)
        return (process.terminationStatus == 0, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Разрешения

enum Permissions {
    /// Проверка «Полного доступа к диску»: эти пути защищены TCC и не вызывают запроса.
    static var hasFullDiskAccess: Bool {
        let home = NSHomeDirectory()
        if (try? FileManager.default.contentsOfDirectory(atPath: home + "/Library/Safari")) != nil { return true }
        if let handle = FileHandle(forReadingAtPath: home + "/Library/Application Support/com.apple.TCC/TCC.db") {
            try? handle.close()
            return true
        }
        return false
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Приложения

enum AppNames {
    struct Resolved {
        let title: String
        let bundleID: String?
        let appPath: String?
    }

    private static var cache: [String: Resolved] = [:]
    private static let lock = NSLock()

    static let friendly: [String: String] = [
        "DiagnosticReports": "Отчёты о сбоях",
        "com.apple.bird": "iCloud Drive (bird)",
        "com.apple.iconservices.store": "Кэш иконок",
        "GeoServices": "Карты (GeoServices)",
        "com.apple.helpd": "Справка macOS",
        "com.apple.parsecd": "Siri Suggestions",
        "com.apple.nsurlsessiond": "Фоновые загрузки",
        "com.apple.touristd": "Советы macOS",
        "com.apple.AppleMediaServices": "Медиа-сервисы Apple",
        "com.apple.amsengagementd": "Медиа-сервисы Apple (engagement)",
        "CrashReporter": "Отчёты о сбоях (CrashReporter)",
        "Homebrew": "Homebrew",
    ]

    static func looksLikeBundleID(_ s: String) -> Bool {
        !s.hasPrefix(".") && !s.contains(" ") && s.split(separator: ".").count >= 2
    }

    static func resolve(_ identifier: String) -> Resolved {
        lock.lock()
        if let hit = cache[identifier] { lock.unlock(); return hit }
        lock.unlock()

        var result = Resolved(title: friendly[identifier] ?? identifier,
                              bundleID: looksLikeBundleID(identifier) ? identifier : nil, appPath: nil)
        if looksLikeBundleID(identifier),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            result = Resolved(title: friendly[identifier] ?? name, bundleID: identifier, appPath: url.path)
        }
        lock.lock(); cache[identifier] = result; lock.unlock()
        return result
    }

    /// "group.com.apple.notes" / "ABCDE12345.com.foo.bar" → "com.apple.notes" / "com.foo.bar"
    static func stripGroupPrefix(_ id: String) -> String {
        var s = id
        if s.hasPrefix("group.") { s.removeFirst(6) }
        if let range = s.range(of: #"^[A-Z0-9]{10}\."#, options: .regularExpression) { s.removeSubrange(range) }
        if s.hasPrefix("group.") { s.removeFirst(6) }
        return s
    }
}

struct RunningApps {
    let bundleIDs: Set<String>
    let names: Set<String>

    static func snapshot() -> RunningApps {
        let apps = NSWorkspace.shared.runningApplications
        let ids = Set(apps.compactMap { $0.bundleIdentifier?.lowercased() })
        var names = Set(apps.compactMap { $0.localizedName?.lowercased() })
        names.formUnion(apps.compactMap { $0.executableURL?.lastPathComponent.lowercased() })
        return RunningApps(bundleIDs: ids, names: names)
    }

    func isRunning(bundleID: String?, processName: String?) -> Bool {
        if let id = bundleID?.lowercased(), bundleIDs.contains(id) { return true }
        if let name = processName?.lowercased(), names.contains(name) { return true }
        return false
    }
}

// MARK: - Том и снимки

struct VolumeInfo {
    let name: String
    let total: Int64
    let available: Int64
    let availableForImportant: Int64

    /// Место, которое macOS может освободить сама (кэши iCloud, снимки и т.п.).
    var purgeable: Int64 { max(0, availableForImportant - available) }
    var usedIncludingPurgeable: Int64 { total - available }
    var usedExcludingPurgeable: Int64 { total - max(available, availableForImportant) }

    static func current(path: String = "/") -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage ?? Int64(available)
        return VolumeInfo(name: values.volumeName ?? "Macintosh HD", total: Int64(total),
                          available: Int64(available), availableForImportant: important)
    }
}

enum LocalSnapshots {
    /// Локальные снимки Time Machine на загрузочном томе.
    static func list() -> [String] {
        let result = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        guard result.ok else { return [] }
        return result.message.split(separator: "\n").map(String.init).filter { $0.contains("com.apple.TimeMachine.") }
    }

    static func date(of snapshot: String) -> String? {
        guard let range = snapshot.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
        return String(snapshot[range])
    }

    static func delete(_ snapshots: [String]) -> (ok: Bool, message: String) {
        let commands = snapshots.compactMap(date(of:)).map { "/usr/bin/tmutil deletelocalsnapshots \($0)" }
        guard !commands.isEmpty else { return (true, "") }
        return Privileged.run(commands.joined(separator: "; "))
    }
}
