import SwiftUI
import UniformTypeIdentifiers

struct AnalyzerView: View {
    @EnvironmentObject private var model: AnalyzerModel
    @EnvironmentObject private var cache: CacheModel
    @State private var hoveredID: Int?

    var body: some View {
        VStack(spacing: 0) {
            if model.isScanning {
                ScanningView()
            } else if let focus = model.focus {
                toolbar(focus)
                Divider()
                HSplitView {
                    NodeList(focus: focus)
                        .frame(minWidth: 320, idealWidth: 400)
                    chartPane(focus)
                        .frame(minWidth: 420)
                }
                Divider()
                CollectorBar()
            } else {
                StartView()
            }
        }
        .alert("Готово", isPresented: Binding(get: { model.alertMessage != nil },
                                              set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private func toolbar(_ focus: FileNode) -> some View {
        HStack(spacing: 6) {
            Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                .disabled(focus.parent == nil)
                .help("На уровень выше")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(focus.lineage.enumerated()), id: \.element.id) { index, node in
                        if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                        Button(index == 0 ? model.rootTitle : node.name) { model.setFocus(node) }
                            .buttonStyle(.plain)
                            .foregroundStyle(node === focus ? Color.primary : Color.accentColor)
                            .fontWeight(node === focus ? .semibold : .regular)
                    }
                }
            }
            Spacer()
            Text("\(Fmt.count(model.scannedFiles)) файлов за \(String(format: "%.1f", model.scanDuration)) с")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                Button("Домашняя папка") { model.scan(path: AnalyzerModel.homePath, title: "Домашняя папка") }
                Button("Весь диск") { model.scan(path: AnalyzerModel.dataVolumePath, title: VolumeInfo.current()?.name ?? "Macintosh HD") }
                Button("Выбрать папку…") { StartView.chooseFolder(model) }
            } label: {
                Label("Сканировать", systemImage: "arrow.clockwise")
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func chartPane(_ focus: FileNode) -> some View {
        VStack(spacing: 0) {
            SunburstView(segments: model.segments, focus: focus, hoveredID: $hoveredID,
                         onSelect: { segment in
                             guard let node = segment.node else { return }
                             if node.isDirectory { model.setFocus(node) } else { model.selected = node }
                         },
                         onCenter: { model.goUp() })
                .id(model.revision)
                .padding(8)
            Divider()
            DetailBar()
        }
    }
}

// MARK: - Start / progress

private struct StartView: View {
    @EnvironmentObject private var model: AnalyzerModel
    @EnvironmentObject private var cache: CacheModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 56))
                .foregroundStyle(.linearGradient(colors: [.purple, .blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Анализ занятого места").font(.largeTitle.weight(.semibold))
            Text("Выберите, что просканировать. Затем кликайте по сегментам диаграммы,\nперетаскивайте ненужное в коллектор внизу и удаляйте.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                target(title: VolumeInfo.current()?.name ?? "Macintosh HD", subtitle: volumeSubtitle, symbol: "internaldrive") {
                    model.scan(path: AnalyzerModel.dataVolumePath, title: VolumeInfo.current()?.name ?? "Macintosh HD")
                }
                target(title: "Домашняя папка", subtitle: "~ \(NSUserName())", symbol: "house") {
                    model.scan(path: AnalyzerModel.homePath, title: "Домашняя папка")
                }
                target(title: "Папка…", subtitle: "Выбрать вручную", symbol: "folder") {
                    Self.chooseFolder(model)
                }
            }
            if !cache.hasFullDiskAccess {
                Text("Без «Полного доступа к диску» macOS будет спрашивать разрешения, а часть папок не будет учтена.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var volumeSubtitle: String {
        guard let volume = VolumeInfo.current() else { return "" }
        return "Занято \(Fmt.bytes(volume.usedIncludingPurgeable)) из \(Fmt.bytes(volume.total))"
    }

    private func target(title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 30))
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 180, height: 130)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    static func chooseFolder(_ model: AnalyzerModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Сканировать"
        if panel.runModal() == .OK, let url = panel.url {
            model.scan(path: url.path, title: url.lastPathComponent)
        }
    }
}

private struct ScanningView: View {
    @EnvironmentObject private var model: AnalyzerModel

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Сканирование: \(model.rootTitle)").font(.title2.weight(.semibold))
            Text("\(Fmt.count(model.scannedFiles)) файлов · \(Fmt.bytes(model.scannedBytes))")
                .font(.title3)
                .monospacedDigit()
            Text(model.currentPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
            Button("Остановить") { model.cancelScan() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - List

private struct NodeList: View {
    @EnvironmentObject private var model: AnalyzerModel
    let focus: FileNode

    var body: some View {
        List {
            ForEach(focus.children) { node in
                NodeRow(node: node, total: focus.size, isSelected: model.selected === node)
                    .onTapGesture(count: 2) {
                        if node.isDirectory { model.setFocus(node) } else { NSWorkspace.shared.open(URL(fileURLWithPath: node.path)) }
                    }
                    .simultaneousGesture(TapGesture().onEnded { model.selected = node })
                    .onDrag { NSItemProvider(object: node.path as NSString) }
                    .contextMenu {
                        if node.isDirectory { Button("Открыть в диаграмме") { model.setFocus(node) } }
                        Button("Показать в Finder") { FSUtil.revealInFinder(node.path) }
                        Button("Добавить в коллектор") { model.addToCollector(node) }
                    }
            }
            let small = focus.smallFilesSize + focus.selfSize
            if small > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3.fill").foregroundStyle(.gray).frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Мелкие файлы (\(Fmt.count(focus.smallFilesCount)))").foregroundStyle(.secondary)
                        SizeBar(fraction: Double(small) / Double(max(1, focus.size)), color: .gray)
                    }
                    Text(Fmt.bytes(small)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let hidden = model.hiddenSpace, focus.parent == nil, hidden > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash").foregroundStyle(.orange).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Скрытое пространство")
                        Text("Системный том, снимки, purgeable, папки без доступа")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Fmt.bytes(hidden)).monospacedDigit().foregroundStyle(.orange)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

private struct NodeRow: View {
    let node: FileNode
    let total: Int64
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            ItemIcon(appPath: nil, fallbackPath: node.path)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    if node.isAccessDenied {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange).help("Нет доступа")
                    }
                }
                SizeBar(fraction: Double(node.size) / Double(max(1, total)),
                        color: node.isDirectory ? .accentColor : .teal)
            }
            Text(Fmt.bytes(node.size))
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
            if node.isDirectory {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }
}

// MARK: - Detail & collector

private struct DetailBar: View {
    @EnvironmentObject private var model: AnalyzerModel

    var body: some View {
        HStack(spacing: 10) {
            if let node = model.selected {
                ItemIcon(appPath: nil, fallbackPath: node.path, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name).font(.headline).lineLimit(1)
                    Text(node.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(Fmt.bytes(node.size)).font(.headline).monospacedDigit()
                Button { FSUtil.revealInFinder(node.path) } label: { Image(systemName: "magnifyingglass") }
                    .help("Показать в Finder")
                Button { model.addToCollector(node) } label: { Label("В коллектор", systemImage: "tray.and.arrow.down") }
            } else {
                Text("Клик по папке — войти в неё, клик в центр — назад. Файл или папку из списка можно перетащить в коллектор.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(10)
        .frame(height: 52)
    }
}

private struct CollectorBar: View {
    @EnvironmentObject private var model: AnalyzerModel
    @AppStorage("analyzer.moveToTrash") private var moveToTrash = true
    @State private var isTargeted = false
    @State private var confirm = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full")
                .font(.title2)
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            if model.collector.isEmpty {
                Text("Коллектор пуст — перетащите сюда файлы и папки для удаления")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.collector) { node in
                            HStack(spacing: 4) {
                                ItemIcon(appPath: nil, fallbackPath: node.path, size: 14)
                                Text(node.name).lineLimit(1)
                                Text(Fmt.bytes(node.size)).foregroundStyle(.secondary).monospacedDigit()
                                Button { model.removeFromCollector(node) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                }
                Text(Fmt.bytes(model.collectorSize)).font(.headline).monospacedDigit()
                Toggle("В Корзину", isOn: $moveToTrash)
                Button("Очистить") { model.clearCollector() }
                Button(role: .destructive) { confirm = true } label: {
                    Label("Удалить", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.isDeleting)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
        .onDrop(of: [UTType.plainText, UTType.utf8PlainText], isTargeted: $isTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let path = object as? String else { return }
                    Task { @MainActor in
                        if let node = model.node(atPath: path) { model.addToCollector(node) }
                    }
                }
            }
            return true
        }
        .alert("Удалить \(model.collector.count) объектов?", isPresented: $confirm) {
            Button(moveToTrash ? "В Корзину" : "Удалить навсегда", role: .destructive) {
                model.deleteCollected(toTrash: moveToTrash)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Будет \(moveToTrash ? "перемещено в Корзину" : "удалено безвозвратно") \(Fmt.bytes(model.collectorSize)).")
        }
    }
}
