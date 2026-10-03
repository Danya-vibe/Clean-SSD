import SwiftUI

/// Категории как в «Системные настройки → Основные → Хранилище».
enum StorageCategory: String, CaseIterable, Identifiable {
    case documents, music, mail, applications, developer, photos, iCloud, trash
    case otherUsers, macOS, systemData

    var id: String { rawValue }

    static let userGroup: [StorageCategory] = [.documents, .music, .mail, .applications, .developer, .photos, .iCloud, .trash]
    static let systemGroup: [StorageCategory] = [.otherUsers, .macOS, .systemData]

    var title: String {
        switch self {
        case .documents: return "Документы"
        case .music: return "Музыка"
        case .mail: return "Почта"
        case .applications: return "Приложения"
        case .developer: return "Разработчик"
        case .photos: return "Фото"
        case .iCloud: return "iCloud Drive"
        case .trash: return "Корзина"
        case .otherUsers: return "Другие пользователи и общие файлы"
        case .macOS: return "macOS"
        case .systemData: return "Системные данные"
        }
    }

    var color: Color {
        switch self {
        case .documents: return Color(red: 0.95, green: 0.32, blue: 0.24)
        case .applications: return Color(red: 0.96, green: 0.62, blue: 0.16)
        case .otherUsers: return Color(red: 0.98, green: 0.82, blue: 0.20)
        case .music: return Color(red: 0.98, green: 0.30, blue: 0.45)
        case .mail: return Color(red: 0.20, green: 0.55, blue: 0.98)
        case .developer: return Color(red: 0.55, green: 0.40, blue: 0.90)
        case .photos: return Color(red: 0.40, green: 0.78, blue: 0.35)
        case .iCloud: return Color(red: 0.35, green: 0.75, blue: 0.95)
        case .trash: return Color(red: 0.62, green: 0.48, blue: 0.38)
        case .macOS: return Color(white: 0.62)
        case .systemData: return Color(white: 0.48)
        }
    }

    var symbol: String {
        switch self {
        case .documents: return "doc.fill"
        case .music: return "music.note"
        case .mail: return "envelope.fill"
        case .applications: return "square.grid.2x2.fill"
        case .developer: return "hammer.fill"
        case .photos: return "photo.fill"
        case .iCloud: return "icloud.fill"
        case .trash: return "trash.fill"
        case .otherUsers: return "person.2.fill"
        case .macOS: return "laptopcomputer"
        case .systemData: return "ellipsis"
        }
    }

    /// Иконка системного приложения, если есть (как в родном «Хранилище»).
    var appBundleID: String? {
        switch self {
        case .music: return "com.apple.Music"
        case .mail: return "com.apple.mail"
        case .photos: return "com.apple.Photos"
        case .developer: return "com.apple.dt.Xcode"
        default: return nil
        }
    }

    var detailHint: String {
        switch self {
        case .documents: return "Файлы в домашней папке: Рабочий стол, Документы, Загрузки, Фильмы и др."
        case .music: return "Медиатека и файлы в папке «Музыка»"
        case .mail: return "Письма и вложения Почты"
        case .applications: return "Программы и их данные (Application Support, контейнеры приложений)"
        case .developer: return "Xcode, Command Line Tools, симуляторы и кэш инструментов разработчика"
        case .photos: return "Медиатеки Фото"
        case .iCloud: return "Локальные копии файлов iCloud Drive"
        case .trash: return "Файлы в Корзине"
        case .otherUsers: return "Папки других пользователей и /Users/Shared. Чужие папки без пароля администратора не читаются."
        case .macOS: return "Системный том и служебные тома APFS (Preboot, Recovery, Update). Удалять нельзя."
        case .systemData: return "Всё остальное: кэш, журналы, файл подкачки, снимки Time Machine, служебные данные приложений."
        }
    }

    /// Можно ли показывать содержимое и удалять его.
    var isBrowsable: Bool { self != .macOS && self != .systemData }
}

/// Где на диске лежат данные каждой категории.
enum StorageLayout {
    static let home = NSHomeDirectory()

    static let developerDotFolders = [".npm", ".gradle", ".m2", ".cargo", ".rustup", ".cache", ".bun", ".pnpm-store",
                                      ".nvm", ".pyenv", ".conda", ".docker", ".android", "go", ".swiftpm", ".cocoapods"]
    private static let documentsExcluded: Set<String> = Set(["Library", "Music", "Pictures", ".Trash", "Applications"] + developerDotFolders)

    static func roots(for category: StorageCategory) -> [String] {
        let h = home
        switch category {
        case .documents:
            var roots = (FSUtil.children(of: h) ?? []).filter { !documentsExcluded.contains(($0 as NSString).lastPathComponent) }
            roots += (FSUtil.children(of: h + "/Pictures") ?? []).filter { !$0.hasSuffix(".photoslibrary") }
            return roots
        case .music:
            return [h + "/Music"]
        case .mail:
            return [h + "/Library/Mail", h + "/Library/Containers/com.apple.mail"]
        case .applications:
            // Как в macOS: программы и их данные. Group Containers macOS относит к «Системным данным».
            var roots = ["/Applications", h + "/Applications", h + "/Library/Application Support"]
            roots += (FSUtil.children(of: h + "/Library/Containers") ?? []).filter { !$0.hasSuffix("/com.apple.mail") }
            return roots
        case .developer:
            return [h + "/Library/Developer", "/Library/Developer"] + developerDotFolders.map { h + "/" + $0 }
        case .photos:
            return (FSUtil.children(of: h + "/Pictures") ?? []).filter { $0.hasSuffix(".photoslibrary") }
        case .iCloud:
            return [h + "/Library/Mobile Documents"]
        case .trash:
            return [h + "/.Trash"]
        case .otherUsers:
            let me = (h as NSString).lastPathComponent
            return (FSUtil.children(of: "/Users") ?? []).filter {
                let name = ($0 as NSString).lastPathComponent
                return name != me && !name.hasPrefix(".") && FSUtil.isDirectory($0)
            }
        case .macOS, .systemData:
            return []
        }
    }

    /// Папки, содержимое которых в окне подробностей показывается поштучно.
    static func expandsChildren(_ path: String, in category: StorageCategory) -> Bool {
        switch category {
        case .documents, .photos: return false
        case .applications:
            return path == "/Applications" || path.hasSuffix("/Applications") || path.hasSuffix("/Application Support")
        default:
            return FSUtil.isDirectory(path) && !path.hasSuffix(".photoslibrary")
        }
    }
}

/// Размеры служебных томов APFS загрузочного контейнера.
enum APFSVolumes {
    struct Volume: Identifiable {
        let name: String
        let role: String
        let used: Int64
        var id: String { name + role }
    }

    /// Служебные тома всех APFS-контейнеров на физическом диске загрузочного тома
    /// (Recovery на Apple Silicon лежит в отдельном контейнере — macOS тоже его учитывает).
    static func systemVolumes() -> [Volume] {
        guard let info = plist(["info", "-plist", "/"]),
              let bootContainer = info["APFSContainerReference"] as? String,
              let list = plist(["apfs", "list", "-plist"]),
              let containers = list["Containers"] as? [[String: Any]],
              let boot = containers.first(where: { $0["ContainerReference"] as? String == bootContainer }) else { return [] }
        let bootDisks = Set(physicalDisks(of: boot))
        let systemRoles: Set<String> = ["System", "Preboot", "Recovery", "Update"]
        var result: [Volume] = []
        for container in containers where !bootDisks.isDisjoint(with: physicalDisks(of: container)) {
            for volume in container["Volumes"] as? [[String: Any]] ?? [] {
                let roles = volume["Roles"] as? [String] ?? []
                guard let role = roles.first(where: systemRoles.contains) else { continue }
                let used = (volume["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
                let name = volume["Name"] as? String ?? role
                let device = volume["DeviceIdentifier"] as? String ?? ""
                result.append(Volume(name: "\(name) (\(device))", role: role, used: used))
            }
        }
        return result.sorted { $0.used > $1.used }
    }

    /// "disk0s2" → "disk0"
    private static func physicalDisks(of container: [String: Any]) -> [String] {
        let stores = container["PhysicalStores"] as? [[String: Any]] ?? []
        return stores.compactMap { $0["DeviceIdentifier"] as? String }.map { id in
            guard let range = id.range(of: #"^disk\d+"#, options: .regularExpression) else { return id }
            return String(id[range])
        }
    }

    private static func plist(_ arguments: [String]) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
