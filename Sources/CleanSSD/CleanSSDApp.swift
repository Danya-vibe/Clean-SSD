import SwiftUI
import AppKit

@main
struct CleanSSDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var cache = CacheModel()
    @StateObject private var analyzer = AnalyzerModel()
    @StateObject private var storage = StorageModel()

    init() {
        if CommandLine.arguments.contains("--storage") {
            CLIReport.storage()
            exit(0)
        }
        if CommandLine.arguments.contains("--report") {
            CLIReport.run(arguments: CommandLine.arguments)
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Clean SSD") {
            ContentView()
                .environmentObject(cache)
                .environmentObject(analyzer)
                .environmentObject(storage)
                .frame(minWidth: 900, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        }
        .defaultSize(width: 1150, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DebugSnapshot.scheduleIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case storage, cache, analyzer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .storage: return "Хранилище"
        case .cache: return "Очистка кэша"
        case .analyzer: return "Анализ диска"
        }
    }

    var symbol: String {
        switch self {
        case .storage: return "internaldrive"
        case .cache: return "sparkles"
        case .analyzer: return "chart.pie"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem? = SidebarItem(rawValue: ProcessInfo.processInfo.environment["CLEANSSD_TAB"] ?? "") ?? .storage

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch selection ?? .cache {
            case .storage: StorageView(selection: $selection)
            case .cache: CacheView()
            case .analyzer: AnalyzerView()
            }
        }
    }
}

/// Отладка: `CLEANSSD_SNAPSHOT=/путь/shot.png` — через несколько секунд окно сохранит снимок самого себя.
enum DebugSnapshot {
    static func scheduleIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CLEANSSD_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["CLEANSSD_SNAPSHOT_DELAY"] ?? "6") ?? 6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let main = NSApp.windows.first(where: { $0.isVisible }),
                  case let window = main.attachedSheet ?? main,
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            var log = "window \(window.frame) content \(window.contentView?.frame ?? .zero)\n"
            func walk(_ v: NSView, _ depth: Int) {
                if v is NSScrollView || depth < 4 {
                    log += String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame)"
                    if let sv = v as? NSScrollView {
                        log += " docFrame=\(sv.documentView?.frame ?? .zero) clipOrigin=\(sv.contentView.bounds.origin) insets=\(sv.contentInsets)"
                    }
                    log += "\n"
                }
                v.subviews.forEach { walk($0, depth + 1) }
            }
            walk(view, 0)
            try? log.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }
}
