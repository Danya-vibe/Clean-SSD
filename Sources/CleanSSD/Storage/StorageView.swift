import SwiftUI

struct StorageView: View {
    @EnvironmentObject private var storage: StorageModel
    @EnvironmentObject private var cache: CacheModel
    @Binding var selection: SidebarItem?
    @State private var detail: StorageCategory?
    @State private var confirmAutoTrash = false
    @State private var confirmSnapshots = false
    @State private var snapshotError: String?
    private static let topID = "storage-top"

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                diskCard
                Text("Рекомендации").font(.headline).padding(.top, 4)
                recommendations
                categoryCard(StorageCategory.userGroup)
                categoryCard(StorageCategory.systemGroup)
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
            .id(Self.topID)
        }
        // Пока идёт подсчёт, высота страницы меняется. Без якоря AppKit держит позицию
        // от нижнего края, и начало страницы уезжает под заголовок окна.
        .topScrollAnchor()
        .onAppear {
            // На macOS 14+ это делает defaultScrollAnchor; scrollTo там не учитывает высоту заголовка окна.
            if #unavailable(macOS 14.0) { proxy.scrollTo(Self.topID, anchor: .top) }
        }
        }
        .onAppear {
            if !storage.hasScanned { storage.refresh() }
            if let name = ProcessInfo.processInfo.environment["CLEANSSD_DETAIL"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { detail = StorageCategory(rawValue: name) }
            }
            if !cache.hasScanned { cache.scan() }
        }
        .sheet(item: $detail) { category in
            StorageDetailSheet(category: category, selection: $selection)
        }
        .alert("Включить автоматическую очистку Корзины?", isPresented: $confirmAutoTrash) {
            Button("Включить") { storage.setAutoEmptyTrash(true) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Объекты, пролежавшие в Корзине более 30 дней, будут удаляться автоматически (настройка Finder).")
        }
        .alert("Удалить локальные снимки Time Machine?", isPresented: $confirmSnapshots) {
            Button("Удалить", role: .destructive) {
                Task { snapshotError = await storage.deleteSnapshots() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Резервные копии на внешнем диске не затрагиваются. Потребуется пароль администратора.")
        }
    }

    // MARK: Диск

    private var diskCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(storage.volume?.name ?? "Macintosh HD").font(.headline)
                    Spacer()
                    if let volume = storage.volume {
                        Text("Используется: \(Fmt.bytes(storage.used)) из \(Fmt.bytes(volume.total))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button {
                        storage.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Пересчитать")
                    .disabled(storage.isScanning)
                }
                StorageBar()
                    .frame(height: 22)
                FlowLayout(spacing: 14, lineSpacing: 6) {
                    ForEach(legendCategories) { category in
                        HStack(spacing: 5) {
                            Circle().fill(category.color).frame(width: 8, height: 8)
                            Text(category.title)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Подсчёт…").font(.caption).foregroundStyle(.secondary)
                }
                .opacity(storage.isScanning ? 1 : 0)
                .frame(height: storage.isScanning ? nil : 0)
                .clipped()
            }
        }
    }

    private var legendCategories: [StorageCategory] {
        let total = max(1, storage.used)
        return StorageBar.order.filter { (storage.size(of: $0) ?? 0) * 100 / total >= 1 }
    }

    // MARK: Рекомендации

    private var recommendations: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                RecommendationRow(
                    icon: AnyView(SymbolTile(symbol: "sparkles", color: .purple)),
                    title: "Очистка кэша и мусора",
                    text: cache.hasScanned
                        ? "Найдено \(Fmt.bytes(cache.totalSize)) кэша, журналов и временных файлов. Приложения создадут нужное заново."
                        : "Поиск кэша, журналов и временных файлов…",
                    button: "Очистить…") { selection = .cache }
                Divider().padding(.leading, 56)
                RecommendationRow(
                    icon: AnyView(SymbolTile(symbol: "trash.fill", color: .gray)),
                    title: "Автоматическая очистка Корзины",
                    text: "Для экономии места на диске автоматически удаляйте объекты, находящиеся в Корзине более 30 дней.",
                    button: storage.autoEmptyTrash ? "Включено" : "Включить…",
                    disabled: storage.autoEmptyTrash) { confirmAutoTrash = true }
                if !storage.snapshots.isEmpty {
                    Divider().padding(.leading, 56)
                    RecommendationRow(
                        icon: AnyView(SymbolTile(symbol: "clock.arrow.circlepath", color: .teal)),
                        title: "Локальные снимки Time Machine (\(storage.snapshots.count))",
                        text: snapshotError ?? "Снимки занимают скрытое место в «Системных данных». macOS удаляет их сама через 24 часа или при нехватке места.",
                        button: "Удалить…") { confirmSnapshots = true }
                }
                if !cache.hasFullDiskAccess {
                    Divider().padding(.leading, 56)
                    RecommendationRow(
                        icon: AnyView(SymbolTile(symbol: "lock.shield.fill", color: .orange)),
                        title: "Полный доступ к диску",
                        text: "Без него размеры Почты, контейнеров приложений и iCloud Drive будут неполными, а macOS будет спрашивать разрешения.",
                        button: "Открыть настройки…") { Permissions.openFullDiskAccessSettings() }
                }
            }
        }
    }

    // MARK: Категории

    private func categoryCard(_ categories: [StorageCategory]) -> some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                    if index > 0 { Divider().padding(.leading, 56) }
                    CategoryRow(category: category,
                                size: storage.size(of: category),
                                partial: storage.partial.contains(category)) { detail = category }
                }
            }
        }
    }
}

// MARK: - Компоненты

private extension View {
    @ViewBuilder
    func topScrollAnchor() -> some View {
        if #available(macOS 14.0, *) {
            defaultScrollAnchor(.top)
        } else {
            self
        }
    }
}

struct StorageBar: View {
    @EnvironmentObject private var storage: StorageModel
    /// `CLEANSSD_HOVER=documents` — отладка: подсказка показана сразу.
    @State private var hovered: String? = ProcessInfo.processInfo.environment["CLEANSSD_HOVER"]

    static let order: [StorageCategory] = [.documents, .applications, .otherUsers, .music, .mail, .developer,
                                           .photos, .iCloud, .trash, .macOS, .systemData]

    private struct Segment: Identifiable {
        let id: String
        let title: String
        let size: Int64
        let color: Color
        let x: CGFloat
        let width: CGFloat
        var isFree: Bool { id == "free" }
    }

    private func segments(width: CGFloat) -> [Segment] {
        let total = Double(max(1, storage.volume?.total ?? 1))
        var result: [Segment] = []
        var x: CGFloat = 0
        for category in Self.order {
            let size = storage.size(of: category) ?? 0
            guard size > 0 else { continue }
            let w = max(1, width * CGFloat(Double(size) / total))
            result.append(Segment(id: category.id, title: category.title, size: size, color: category.color, x: x, width: w))
            x += w + 1
        }
        result.append(Segment(id: "free", title: "Свободно", size: storage.free,
                              color: Color.secondary.opacity(0.18), x: x, width: max(0, width - x)))
        return result
    }

    var body: some View {
        GeometryReader { geo in
            let items = segments(width: geo.size.width)
            ZStack(alignment: .topLeading) {
                ForEach(items) { segment in
                    ZStack {
                        Rectangle().fill(segment.color)
                        if segment.isFree {
                            Text(Fmt.bytes(segment.size))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                    }
                    .frame(width: segment.width, height: geo.size.height)
                    .opacity(hovered == nil || hovered == segment.id ? 1 : 0.55)
                    .offset(x: segment.x)
                }
            }
            // offset не влияет на раскладку, поэтому задаём ширину всей полосы явно.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let id = items.first { point.x >= $0.x && point.x < $0.x + $0.width + 1 }?.id
                    if id != hovered { hovered = id }
                case .ended:
                    hovered = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let segment = items.first(where: { $0.id == hovered }) {
                    // Точка-якорь над серединой сегмента; подсказка растёт от неё вверх.
                    Color.clear
                        .frame(width: 1, height: 1)
                        .overlay(alignment: .bottom) {
                            BarTooltip(title: segment.title, size: segment.size).fixedSize()
                        }
                        .offset(x: segment.x + segment.width / 2, y: -2)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hovered)
        }
        .animation(.easeOut(duration: 0.3), value: storage.sizes)
    }
}

/// Всплывающая подсказка над полосой, как в «Хранилище» macOS.
private struct BarTooltip: View {
    let title: String
    let size: Int64

    var body: some View {
        VStack(spacing: 1) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(Fmt.bytes(size)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            TooltipShape()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            TooltipShape()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        }
        .padding(.bottom, 6)
    }
}

/// Скруглённый прямоугольник со стрелкой вниз.
private struct TooltipShape: Shape {
    func path(in rect: CGRect) -> Path {
        let arrow: CGFloat = 6
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        var path = Path(roundedRect: body, cornerRadius: 7)
        path.move(to: CGPoint(x: rect.midX - arrow, y: body.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: body.maxY + arrow))
        path.addLine(to: CGPoint(x: rect.midX + arrow, y: body.maxY))
        path.closeSubpath()
        return path
    }
}

private struct CategoryRow: View {
    let category: StorageCategory
    let size: Int64?
    let partial: Bool
    let onInfo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: category)
            Text(category.title)
            Spacer()
            if let size {
                if partial {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Часть данных недоступна — нужен полный доступ к диску")
                }
                Text(partial && size == 0 ? "Нет доступа" : Fmt.bytes(size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
            }
            Button(action: onInfo) {
                Image(systemName: "info.circle").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Подробнее")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onInfo)
    }
}

struct CategoryIcon: View {
    let category: StorageCategory
    var size: CGFloat = 28

    var body: some View {
        if let bundleID = category.appBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: size, height: size)
        } else {
            SymbolTile(symbol: category.symbol, color: category == .macOS || category == .systemData ? .gray : category.color, size: size)
        }
    }
}

struct SymbolTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white))
    }
}

private struct RecommendationRow: View {
    let icon: AnyView
    let title: String
    let text: String
    let button: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            Spacer(minLength: 16)
            Button(button, action: action)
                .disabled(disabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
    }
}

/// Перенос элементов легенды на новую строку.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
