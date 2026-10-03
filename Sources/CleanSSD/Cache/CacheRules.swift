import Foundation
import Darwin

enum CacheCategory: String, CaseIterable, Identifiable {
    case system, user, sandboxed, browsers, electron, developer, xcode, logs, temp, downloads, trash, backups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Системный кэш"
        case .user: return "Кэш приложений"
        case .sandboxed: return "Кэш изолированных приложений"
        case .browsers: return "Браузеры"
        case .electron: return "Кэш Electron-приложений"
        case .developer: return "Инструменты разработчика"
        case .xcode: return "Xcode и симуляторы"
        case .logs: return "Журналы и отчёты о сбоях"
        case .temp: return "Временные файлы"
        case .downloads: return "Загрузки и установщики"
        case .trash: return "Корзина"
        case .backups: return "Резервные копии iOS"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "/Library/Caches — общий кэш macOS и служб (нужен пароль администратора)"
        case .user: return "~/Library/Caches — кэш программ пользователя"
        case .sandboxed: return "Контейнеры приложений из App Store и системных программ"
        case .browsers: return "Кэш страниц, скриптов и шейдеров. История и пароли не затрагиваются"
        case .electron: return "Slack, Discord, VS Code, Notion и другие приложения на Electron"
        case .developer: return "Homebrew, npm, pip, Yarn, Gradle, Cargo, ~/.cache…"
        case .xcode: return "DerivedData, DeviceSupport, кэш симуляторов, архивы"
        case .logs: return "~/Library/Logs и /Library/Logs"
        case .temp: return "Старые временные файлы в /var/folders"
        case .downloads: return "Вложения Почты, прошивки iOS, .dmg/.pkg в «Загрузках»"
        case .trash: return "Файлы в Корзине"
        case .backups: return "Локальные резервные копии iPhone и iPad — проверьте перед удалением"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "gearshape.2"
        case .user: return "square.stack.3d.up"
        case .sandboxed: return "shippingbox"
        case .browsers: return "globe"
        case .electron: return "bolt.horizontal"
        case .developer: return "hammer"
        case .xcode: return "swift"
        case .logs: return "doc.text.magnifyingglass"
        case .temp: return "clock.arrow.circlepath"
        case .downloads: return "arrow.down.circle"
        case .trash: return "trash"
        case .backups: return "iphone"
        }
    }
}

enum Safety {
    /// Данные пересоздаются автоматически — можно удалять.
    case safe
    /// Удаление безопасно для системы, но может стоить данных/времени — проверьте.
    case review
}

enum CleanMode: Hashable {
    /// Удалить содержимое папки, саму папку оставить.
    case contents
    /// Удалить только элементы старше N дней.
    case contentsOlderThan(days: Int)
    /// Удалить сам объект.
    case wholeItem
}

struct CacheTarget: Identifiable, Hashable {
    let category: CacheCategory
    let title: String
    let paths: [String]
    var mode: CleanMode = .contents
    var safety: Safety = .safe
    var requiresAdmin = false
    var bundleID: String?
    var processName: String?
    var appPath: String?
    var note: String?

    var id: String { paths.joined(separator: "|") }
}

/// Находит на диске известные места хранения кэша и мусора.
struct CacheDiscovery {
    private(set) var targets: [CacheTarget] = []
    private(set) var locked: Set<CacheCategory> = []
    private var claimed = Set<String>()
    private let home = NSHomeDirectory()
    private let hasFDA: Bool

    static func discover(hasFDA: Bool) -> (targets: [CacheTarget], locked: Set<CacheCategory>) {
        var discovery = CacheDiscovery(hasFDA: hasFDA)
        discovery.run()
        return (discovery.targets, discovery.locked)
    }

    private init(hasFDA: Bool) {
        self.hasFDA = hasFDA
    }

    private mutating func run() {
        // Сначала специфичные правила — они «забирают» свои пути у общих.
        addBrowsers()
        addXcode()
        addDeveloperTools()
        addElectronApps()
        addDownloads()
        addTrash()
        addBackups()
        addTemp()
        addLogs()
        addGeneric(in: h("Library/Caches"), category: .user, admin: false)
        addSandboxed()
        addGeneric(in: "/Library/Caches", category: .system, admin: true)
    }

    // MARK: Helpers

    private func h(_ relative: String) -> String { home + "/" + relative }

    private static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    private mutating func add(_ category: CacheCategory, _ title: String, _ paths: [String],
                              mode: CleanMode = .contents, safety: Safety = .safe, admin: Bool = false,
                              bundleID: String? = nil, processName: String? = nil, appPath: String? = nil,
                              note: String? = nil) {
        var valid: [String] = []
        for path in paths where !claimed.contains(path) && !valid.contains(path)
            && FSUtil.exists(path) && !FSUtil.isSymlink(path) {
            valid.append(path)
        }
        guard !valid.isEmpty else { return }
        claimed.formUnion(valid)
        let app = appPath ?? bundleID.flatMap { AppNames.resolve($0).appPath }
        targets.append(CacheTarget(category: category, title: title, paths: valid, mode: mode, safety: safety,
                                   requiresAdmin: admin, bundleID: bundleID, processName: processName,
                                   appPath: app, note: note))
    }

    private func isClaimedInside(_ path: String) -> Bool {
        let prefix = path + "/"
        return claimed.contains { $0.hasPrefix(prefix) }
    }

    // MARK: Общие каталоги кэша

    /// Системные службы, кэш которых лучше не трогать без необходимости.
    private static let sensitiveNames: Set<String> = [
        "com.apple.bird", "CloudKit", "com.apple.CloudDocs", "com.apple.akd", "FamilyCircle",
        "com.apple.containermanagerd", "com.apple.nsurlsessiond", "com.apple.iCloudHelper",
        "com.apple.ap.adprivacyd", "com.apple.homed", "com.apple.findmy.fmipcore",
    ]
    private static let skipNames: Set<String> = ["com.cleanssd.app"]

    private mutating func addGeneric(in dir: String, category: CacheCategory, admin: Bool,
                                     prefix: String? = nil, depth: Int = 0) {
        guard let items = FSUtil.children(of: dir) else { return }
        for path in items.sorted() {
            let name = Self.name(path)
            if Self.skipNames.contains(name) || claimed.contains(path) { continue }
            if isClaimedInside(path) {
                // Внутри уже есть специфичный кэш (например, Google/Chrome) — раскрываем уровнем глубже.
                if depth < 2 {
                    addGeneric(in: path, category: category, admin: admin,
                               prefix: prefix.map { "\($0) › \(name)" } ?? name, depth: depth + 1)
                }
                continue
            }
            let resolved = AppNames.resolve(name)
            let title = prefix.map { "\($0) › \(resolved.title)" } ?? resolved.title
            add(category, title, [path],
                mode: FSUtil.isDirectory(path) ? .contents : .wholeItem,
                safety: Self.sensitiveNames.contains(name) ? .review : .safe,
                admin: admin, bundleID: resolved.bundleID, appPath: resolved.appPath,
                note: Self.sensitiveNames.contains(name) ? "Служба iCloud/системы — очищайте только при проблемах" : nil)
        }
    }

    private mutating func addSandboxed() {
        // Доступ к контейнерам других приложений без «Полного доступа к диску» вызывает системные запросы.
        guard hasFDA else {
            locked.insert(.sandboxed)
            return
        }
        for container in FSUtil.children(of: h("Library/Containers")) ?? [] {
            var identifier = Self.name(container)
            let metadata = container + "/.com.apple.containermanagerd.metadata.plist"
            if let dict = NSDictionary(contentsOfFile: metadata),
               let id = dict["MCMMetadataIdentifier"] as? String {
                identifier = id
            }
            let resolved = AppNames.resolve(identifier)
            add(.sandboxed, resolved.title, [container + "/Data/Library/Caches"],
                safety: Self.sensitiveNames.contains(identifier) ? .review : .safe,
                bundleID: resolved.bundleID, appPath: resolved.appPath)
        }
        for group in FSUtil.children(of: h("Library/Group Containers")) ?? [] {
            let identifier = AppNames.stripGroupPrefix(Self.name(group))
            let resolved = AppNames.resolve(identifier)
            add(.sandboxed, resolved.title + " (общий контейнер)", [group + "/Library/Caches"],
                bundleID: resolved.bundleID, appPath: resolved.appPath)
        }
    }

    // MARK: Браузеры

    private static let chromiumProfileCaches = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "Service Worker/CacheStorage", "Service Worker/ScriptCache",
    ]
    private static let chromiumRootCaches = ["ShaderCache", "GrShaderCache", "GraphiteDawnCache", "component_crx_cache"]

    private mutating func addBrowsers() {
        var safari = [h("Library/Caches/com.apple.Safari"), h("Library/Caches/com.apple.WebKit.Networking"),
                      h("Library/Caches/com.apple.WebKit.WebContent")]
        if hasFDA { safari.append(h("Library/Containers/com.apple.Safari/Data/Library/Caches")) }
        add(.browsers, "Safari", safari, bundleID: "com.apple.Safari")

        add(.browsers, "Firefox", [h("Library/Caches/Firefox"), h("Library/Caches/Mozilla")],
            bundleID: "org.mozilla.firefox")

        let chromium: [(title: String, bundle: String, cache: String, support: String)] = [
            ("Google Chrome", "com.google.Chrome", "Library/Caches/Google/Chrome", "Library/Application Support/Google/Chrome"),
            ("Яндекс Браузер", "ru.yandex.desktop.yandex-browser", "Library/Caches/Yandex/YandexBrowser", "Library/Application Support/Yandex/YandexBrowser"),
            ("Microsoft Edge", "com.microsoft.edgemac", "Library/Caches/Microsoft Edge", "Library/Application Support/Microsoft Edge"),
            ("Brave", "com.brave.Browser", "Library/Caches/BraveSoftware/Brave-Browser", "Library/Application Support/BraveSoftware/Brave-Browser"),
            ("Opera", "com.operasoftware.Opera", "Library/Caches/com.operasoftware.Opera", "Library/Application Support/com.operasoftware.Opera"),
            ("Vivaldi", "com.vivaldi.Vivaldi", "Library/Caches/Vivaldi", "Library/Application Support/Vivaldi"),
            ("Arc", "company.thebrowser.Browser", "Library/Caches/Arc", "Library/Application Support/Arc/User Data"),
            ("Chromium", "org.chromium.Chromium", "Library/Caches/Chromium", "Library/Application Support/Chromium"),
        ]
        for browser in chromium {
            let support = h(browser.support)
            var paths = [h(browser.cache)]
            // У Opera папка поддержки сама является профилем.
            paths += Self.chromiumProfileCaches.map { support + "/" + $0 }
            for profile in FSUtil.children(of: support) ?? [] {
                let name = Self.name(profile)
                guard name == "Default" || name.hasPrefix("Profile ") || name == "Guest Profile" else { continue }
                paths += Self.chromiumProfileCaches.map { profile + "/" + $0 }
            }
            paths += Self.chromiumRootCaches.map { support + "/" + $0 }
            add(.browsers, browser.title, paths, bundleID: browser.bundle)
        }
    }

    // MARK: Electron

    private static let electronCaches = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "Service Worker/CacheStorage", "Service Worker/ScriptCache", "CachedData", "CachedExtensionVSIXs",
        "Crashpad/completed",
    ]
    private static let electronBundleIDs: [String: String] = [
        "Slack": "com.tinyspeck.slackmacgap", "discord": "com.hnc.Discord", "Code": "com.microsoft.VSCode",
        "Cursor": "com.todesktop.230313mzl4w4u92", "Notion": "notion.id", "Figma": "com.figma.Desktop",
        "Postman": "com.postmanlabs.mac", "obsidian": "md.obsidian", "Microsoft Teams": "com.microsoft.teams2",
        "Claude": "com.anthropic.claudefordesktop", "WhatsApp": "net.whatsapp.WhatsApp",
        "Telegram Desktop": "com.tdesktop.Telegram", "Spotify": "com.spotify.client", "Zoom": "us.zoom.xos",
    ]

    private mutating func addElectronApps() {
        for dir in FSUtil.children(of: h("Library/Application Support")) ?? [] {
            guard FSUtil.isDirectory(dir), !isClaimedInside(dir) else { continue }
            guard FSUtil.exists(dir + "/Code Cache") || FSUtil.exists(dir + "/GPUCache") else { continue }
            let name = Self.name(dir)
            let bundleID = Self.electronBundleIDs[name]
            let title = bundleID.map { AppNames.resolve($0).title }.flatMap { $0 == bundleID ? nil : $0 } ?? name
            add(.electron, title, Self.electronCaches.map { dir + "/" + $0 },
                bundleID: bundleID, processName: name)
        }
    }

    // MARK: Разработка

    private mutating func addDeveloperTools() {
        add(.developer, "Homebrew", [h("Library/Caches/Homebrew")], note: "Скачанные бутылки и исходники")
        add(.developer, "pip (Python)", [h("Library/Caches/pip")])
        add(.developer, "Poetry", [h("Library/Caches/pypoetry")])
        add(.developer, "npm", [h(".npm/_cacache")])
        add(.developer, "Yarn", [h("Library/Caches/Yarn")])
        add(.developer, "Bun", [h(".bun/install/cache")])
        add(.developer, "pnpm store", [h("Library/pnpm/store")], safety: .review,
            note: "Лучше выполнить «pnpm store prune»")
        add(.developer, "node-gyp", [h("Library/Caches/node-gyp")])
        add(.developer, "CocoaPods", [h("Library/Caches/CocoaPods")])
        add(.developer, "Swift Package Manager", [h("Library/Caches/org.swift.swiftpm")])
        add(.developer, "Gradle", [h(".gradle/caches")], note: "Зависимости будут скачаны при следующей сборке")
        add(.developer, "Maven (~/.m2)", [h(".m2/repository")], safety: .review,
            note: "Локальный репозиторий — зависимости будут скачаны заново")
        add(.developer, "Cargo (Rust)", [h(".cargo/registry/cache"), h(".cargo/registry/src")])
        add(.developer, "Go build cache", [h("Library/Caches/go-build")])
        add(.developer, "Composer (PHP)", [h("Library/Caches/composer"), h(".composer/cache")])
        add(.developer, "JetBrains IDE", [h("Library/Caches/JetBrains")], bundleID: nil,
            note: "Индексы IDE будут перестроены")
        add(.developer, "Playwright (браузеры)", [h("Library/Caches/ms-playwright")], safety: .review,
            note: "Браузеры для тестов, скачиваются заново")
        add(.developer, "Conda pkgs", [h("miniconda3/pkgs"), h("anaconda3/pkgs"), h("miniforge3/pkgs"),
                                       h("opt/anaconda3/pkgs"), h("opt/miniconda3/pkgs")],
            safety: .review, note: "Лучше выполнить «conda clean --all»")
        for item in (FSUtil.children(of: h(".cache")) ?? []).sorted() {
            add(.developer, "~/.cache › " + Self.name(item), [item],
                mode: FSUtil.isDirectory(item) ? .contents : .wholeItem, safety: .review,
                note: "Может содержать скачанные модели и данные (например, huggingface)")
        }
    }

    private mutating func addXcode() {
        let xcode = "com.apple.dt.Xcode"
        add(.xcode, "DerivedData", [h("Library/Developer/Xcode/DerivedData")], bundleID: xcode,
            note: "Промежуточные файлы сборки, пересоздаются")
        add(.xcode, "Кэш Xcode", [h("Library/Caches/com.apple.dt.Xcode")], bundleID: xcode)
        for os in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            add(.xcode, "\(os) DeviceSupport", [h("Library/Developer/Xcode/\(os) DeviceSupport")],
                note: "Символы отладки; загрузятся при следующем подключении устройства")
        }
        add(.xcode, "Кэш симуляторов", [h("Library/Developer/CoreSimulator/Caches")])
        add(.xcode, "Превью SwiftUI", [h("Library/Developer/Xcode/UserData/Previews")])
        add(.xcode, "Кэш документации", [h("Library/Developer/Xcode/DocumentationCache")])
        add(.xcode, "Архивы Xcode", [h("Library/Developer/Xcode/Archives")], safety: .review,
            note: "Содержат сборки для публикации и dSYM")
    }

    // MARK: Журналы, временные файлы

    private mutating func addLogs() {
        for item in (FSUtil.children(of: h("Library/Logs")) ?? []).sorted() {
            let resolved = AppNames.resolve(Self.name(item))
            add(.logs, resolved.title, [item], mode: FSUtil.isDirectory(item) ? .contents : .wholeItem,
                appPath: resolved.appPath)
        }
        for item in (FSUtil.children(of: "/Library/Logs") ?? []).sorted() {
            let resolved = AppNames.resolve(Self.name(item))
            add(.logs, resolved.title + " (системные)", [item],
                mode: FSUtil.isDirectory(item) ? .contents : .wholeItem, admin: true, appPath: resolved.appPath)
        }
    }

    private mutating func addTemp() {
        var tmp = NSTemporaryDirectory()
        while tmp.count > 1 && tmp.hasSuffix("/") { tmp.removeLast() }
        add(.temp, "Временные файлы старше 3 дней", [tmp], mode: .contentsOlderThan(days: 3),
            note: tmp)
        if let userCache = FSUtil.confstrPath(_CS_DARWIN_USER_CACHE_DIR) {
            add(.temp, "Кэш macOS пользователя, старше 7 дней", [userCache], mode: .contentsOlderThan(days: 7),
                safety: .review, note: "Может потребоваться перезапуск некоторых программ")
        }
    }

    // MARK: Загрузки, корзина, резервные копии

    private mutating func addDownloads() {
        if hasFDA {
            add(.downloads, "Вложения Почты", [h("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")],
                bundleID: "com.apple.mail", note: "Копии открытых вложений; письма остаются на месте")
        }
        add(.downloads, "Прошивки iPhone", [h("Library/iTunes/iPhone Software Updates")])
        add(.downloads, "Прошивки iPad", [h("Library/iTunes/iPad Software Updates")])
        if hasFDA {
            let extensions: Set<String> = ["dmg", "pkg", "mpkg", "ipsw", "xip"]
            let installers = (FSUtil.children(of: h("Downloads")) ?? []).filter {
                extensions.contains(($0 as NSString).pathExtension.lowercased())
            }
            add(.downloads, "Установщики в «Загрузках»", installers, mode: .wholeItem, safety: .review,
                note: "\(installers.count) файлов .dmg / .pkg / .ipsw / .xip")
        }
    }

    private mutating func addTrash() {
        let trash = h(".Trash")
        if FSUtil.children(of: trash) == nil {
            locked.insert(.trash)
        } else {
            add(.trash, "Корзина", [trash], note: "Файлы будут удалены безвозвратно")
        }
    }

    private mutating func addBackups() {
        let dir = h("Library/Application Support/MobileSync/Backup")
        guard hasFDA else {
            if FSUtil.exists(h("Library/Application Support/MobileSync")) { locked.insert(.backups) }
            return
        }
        for backup in FSUtil.children(of: dir) ?? [] {
            let info = NSDictionary(contentsOfFile: backup + "/Info.plist")
            let device = info?["Device Name"] as? String ?? Self.name(backup)
            var title = device
            if let date = info?["Last Backup Date"] as? Date {
                title += " — " + date.formatted(date: .abbreviated, time: .omitted)
            }
            add(.backups, title, [backup], mode: .wholeItem, safety: .review,
                note: "Удаление резервной копии необратимо")
        }
    }
}
