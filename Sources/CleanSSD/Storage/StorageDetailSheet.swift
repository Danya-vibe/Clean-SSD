import SwiftUI

struct StorageDetailSheet: View {
    @EnvironmentObject private var storage: StorageModel
    @Environment(\.dismiss) private var dismiss
    let category: StorageCategory
    @Binding var selection: SidebarItem?

    private enum Tab: Hashable { case items, large }

    @State private var detail: StorageDetail?
    @State private var components: [StorageEntry] = []
    @State private var tab: Tab = .items
    @State private var pendingDelete: StorageEntry?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 700, height: 560)
        .task { await load() }
        .alert("Переместить в Корзину?", isPresented: Binding(get: { pendingDelete != nil },
                                                             set: { if !$0 { pendingDelete = nil } })) {
            Button("В Корзину", role: .destructive) { if let entry = pendingDelete { trash(entry) } }
            Button("Отмена", role: .cancel) {}
        } message: {
            if let entry = pendingDelete {
                Text("«\(entry.name)» — \(Fmt.bytes(entry.size)). Место освободится после очистки Корзины.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: category, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title).font(.title3.weight(.semibold))
                Text(category.detailHint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let size = storage.size(of: category) {
                Text(Fmt.bytes(size)).font(.title3).monospacedDigit()
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch category {
        case .macOS:
            List(storage.macOSVolumes) { volume in
                HStack {
                    Image(systemName: "internaldrive").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(volume.name)
                        Text("Роль тома: \(volume.role)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Fmt.bytes(volume.used)).monospacedDigit()
                }
            }
        case .systemData:
            VStack(alignment: .leading, spacing: 0) {
                if components.isEmpty {
                    ProgressView("Подсчёт…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section("Что удалось измерить") {
                            ForEach(components) { EntryRow(entry: $0, onTrash: nil) }
                            if let volume = storage.volume, volume.purgeable > 0 {
                                HStack {
                                    Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary).frame(width: 22)
                                    Text("Освобождаемое (снимки, кэш iCloud)")
                                    Spacer()
                                    Text(Fmt.bytes(volume.purgeable)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section {
                            Text("Остальное — служебные данные macOS и программ в ~/Library и /private/var, к которым нет доступа без прав администратора.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Перейти к очистке кэша…") {
                        selection = .cache
                        dismiss()
                    }
                }
                .padding(12)
            }
        default:
            if let detail {
                VStack(spacing: 0) {
                    if !detail.largeFiles.isEmpty {
                        Picker("", selection: $tab) {
                            Text("Папки и файлы").tag(Tab.items)
                            Text("Большие файлы (\(detail.largeFiles.count))").tag(Tab.large)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 360)
                        .padding(10)
                    }
                    let entries = tab == .items ? detail.entries : detail.largeFiles
                    if entries.isEmpty {
                        Text(detail.denied ? "Нет доступа — нужен полный доступ к диску" : "Пусто")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(entries) { entry in
                            EntryRow(entry: entry) { pendingDelete = entry }
                        }
                    }
                }
            } else {
                ProgressView("Подсчёт…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func load() async {
        switch category {
        case .macOS: break
        case .systemData: components = await storage.systemDataComponents()
        default: detail = await storage.loadDetail(for: category)
        }
    }

    private func trash(_ entry: StorageEntry) {
        do {
            try storage.moveToTrash(entry, category: category)
            detail?.entries.removeAll { $0.path == entry.path || $0.path.hasPrefix(entry.path + "/") }
            detail?.largeFiles.removeAll { $0.path == entry.path || $0.path.hasPrefix(entry.path + "/") }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct EntryRow: View {
    let entry: StorageEntry
    let onTrash: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ItemIcon(appPath: nil, fallbackPath: entry.path, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1)
                Text(displayPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if hovering {
                Button { FSUtil.revealInFinder(entry.path) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Показать в Finder")
                if let onTrash {
                    Button(action: onTrash) { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Переместить в Корзину")
                }
            }
            Text(Fmt.bytes(entry.size)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 76, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Показать в Finder") { FSUtil.revealInFinder(entry.path) }
            if let onTrash { Button("Переместить в Корзину", action: onTrash) }
        }
    }

    private var displayPath: String {
        let home = NSHomeDirectory()
        return entry.path.hasPrefix(home) ? "~" + entry.path.dropFirst(home.count) : entry.path
    }
}
