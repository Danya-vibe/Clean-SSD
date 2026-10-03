import SwiftUI

struct CacheView: View {
    @EnvironmentObject private var model: CacheModel
    @AppStorage("cache.moveToTrash") private var moveToTrash = false
    @State private var confirmClean = false

    var body: some View {
        // Шапка и подвал крепятся к безопасной области списка: так список всегда
        // занимает ровно видимую часть окна и прокручивается до самого верха.
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    header
                    Divider()
                    if !model.hasFullDiskAccess {
                        FullDiskAccessBanner { model.refreshPermissions(); model.scan() }
                        Divider()
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    footer
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        .onAppear {
            if !model.hasScanned { model.scan() }
        }
        .alert("Очистить выбранное?", isPresented: $confirmClean) {
            Button("Очистить", role: .destructive) { model.cleanSelected(moveToTrash: moveToTrash) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(confirmationText)
        }
        .alert(item: $model.report) { report in
            Alert(title: Text("Очистка завершена"), message: Text(reportText(report)), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Очистка кэша и мусора").font(.title2.weight(.semibold))
                if model.isScanning {
                    Text("Поиск кэша…").foregroundStyle(.secondary)
                } else if model.hasScanned {
                    Text("Найдено \(Fmt.bytes(model.totalSize)) в \(model.items.count) местах")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu("Выбор") {
                Button("Выбрать всё безопасное") { model.selectAllSafe() }
                Button("Снять выбор") { model.deselectAll() }
            }
            .fixedSize()
            .disabled(model.items.isEmpty)
            Button {
                model.scan()
            } label: {
                Label("Сканировать заново", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning || model.isCleaning)
        }
        .padding(16)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.isScanning && !model.hasScanned {
            VStack(spacing: 12) {
                ProgressView()
                Text("Ищу кэш, журналы и временные файлы…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.hasScanned && model.categories.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(.green)
                Text("Кэш не найден — всё чисто").font(.title3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.categories) { category in
                    DisclosureGroup(isExpanded: expansion(for: category)) {
                        if model.lockedCategories.contains(category) {
                            LockedRow()
                        }
                        ForEach(model.items(in: category)) { item in
                            CacheRow(item: item) { model.toggle(item) }
                        }
                    } label: {
                        CategoryHeader(category: category,
                                       size: model.items(in: category).reduce(0) { $0 + $1.size },
                                       state: model.selectionState(of: category),
                                       locked: model.lockedCategories.contains(category)) { state in
                            model.setSelection(state != .on, in: category)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .overlay {
                if model.isScanning || model.isCleaning {
                    ZStack {
                        Color(nsColor: .windowBackgroundColor).opacity(0.6)
                        ProgressView(model.isCleaning ? "Очистка…" : "Обновление…")
                    }
                }
            }
        }
    }

    private func expansion(for category: CacheCategory) -> Binding<Bool> {
        Binding(
            get: { model.expanded.contains(category) },
            set: { value in
                if value { model.expanded.insert(category) } else { model.expanded.remove(category) }
            }
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Выбрано: \(Fmt.bytes(model.selectedSize))")
                    .font(.headline)
                    .monospacedDigit()
                Text("\(model.selectedItems.count) из \(model.items.count) мест")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Перемещать в Корзину", isOn: $moveToTrash)
                .help("Если включено, место освободится только после очистки Корзины")
            Button {
                confirmClean = true
            } label: {
                Label("Очистить", systemImage: "trash")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.selectedItems.isEmpty || model.isCleaning || model.isScanning)
        }
        .padding(16)
    }

    private var confirmationText: String {
        let selected = model.selectedItems
        var lines = ["Будет удалено \(Fmt.bytes(model.selectedSize)) из \(selected.count) мест."]
        lines.append(moveToTrash ? "Файлы будут перемещены в Корзину." : "Файлы будут удалены безвозвратно.")
        if selected.contains(where: { $0.target.requiresAdmin }) {
            lines.append("Для системного кэша macOS запросит пароль администратора.")
        }
        let running = selected.filter(\.isRunning).map(\.target.title)
        if !running.isEmpty {
            lines.append("Запущены: \(running.prefix(4).joined(separator: ", ")). Лучше закрыть их перед очисткой.")
        }
        if selected.contains(where: { $0.target.safety == .review }) {
            lines.append("Среди выбранного есть элементы с пометкой «Проверьте».")
        }
        return lines.joined(separator: "\n\n")
    }

    private func reportText(_ report: CleanReport) -> String {
        var lines = [report.movedToTrash
                     ? "Перемещено в Корзину: \(Fmt.bytes(report.freed))"
                     : "Освобождено: \(Fmt.bytes(report.freed))"]
        if report.failedCount > 0 {
            lines.append("Не удалось удалить объектов: \(report.failedCount) (используются или защищены системой).")
        }
        if let error = report.adminError { lines.append(error) }
        return lines.joined(separator: "\n\n")
    }
}

// MARK: - Rows

private struct CategoryHeader: View {
    let category: CacheCategory
    let size: Int64
    let state: CheckState
    let locked: Bool
    let onToggle: (CheckState) -> Void

    var body: some View {
        HStack(spacing: 10) {
            TriCheckbox(state: state) { onToggle(state) }
            Image(systemName: category.symbol)
                .font(.system(size: 16))
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.title).font(.headline)
                Text(category.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if locked {
                Image(systemName: "lock.fill").foregroundStyle(.orange).help("Нужен полный доступ к диску")
            }
            Text(Fmt.bytes(size))
                .font(.headline)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

private struct CacheRow: View {
    let item: CacheItem
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TriCheckbox(state: item.isSelected ? .on : .off, action: onToggle)
                .disabled(item.accessDenied)
            ItemIcon(appPath: item.target.appPath, fallbackPath: item.target.paths.first ?? "/")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.target.title).lineLimit(1)
                Text(item.target.note ?? displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if item.isRunning { Badge(text: "Запущено", color: .red) }
            if item.target.safety == .review { Badge(text: "Проверьте", color: .orange) }
            if item.target.requiresAdmin {
                Image(systemName: "lock.shield").foregroundStyle(.secondary).help("Нужен пароль администратора")
            }
            if item.accessDenied {
                Badge(text: "Нет доступа", color: .gray)
            } else {
                Text(Fmt.bytes(item.size))
                    .monospacedDigit()
                    .foregroundStyle(item.isSelected ? .primary : .secondary)
                    .frame(minWidth: 80, alignment: .trailing)
            }
        }
        .padding(.leading, 4)
        .contentShape(Rectangle())
        .help(item.target.paths.joined(separator: "\n"))
        .contextMenu {
            ForEach(item.target.paths, id: \.self) { path in
                Button("Показать в Finder: \((path as NSString).lastPathComponent)") { FSUtil.revealInFinder(path) }
            }
        }
    }

    private var displayPath: String {
        let home = NSHomeDirectory()
        let first = item.target.paths.first ?? ""
        let shown = first.hasPrefix(home) ? "~" + first.dropFirst(home.count) : first
        return item.target.paths.count > 1 ? "\(shown) и ещё \(item.target.paths.count - 1)" : shown
    }
}

private struct LockedRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            Text("Часть данных недоступна без «Полного доступа к диску»")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Открыть настройки") { Permissions.openFullDiskAccessSettings() }
        }
        .padding(.leading, 4)
    }
}
