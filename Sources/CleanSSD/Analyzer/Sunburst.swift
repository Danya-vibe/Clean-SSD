import SwiftUI

struct SunSegment: Identifiable {
    let id: Int
    /// nil — агрегированный сегмент «мелкие объекты».
    let node: FileNode?
    let owner: FileNode
    let depth: Int
    let start: Double
    let end: Double
    let hue: Double
    let size: Int64

    var isFile: Bool { node.map { !$0.isDirectory } ?? false }
}

enum SunburstLayout {
    static let maxDepth = 6
    static let minAngle = 0.006

    static func build(focus: FileNode) -> [SunSegment] {
        var segments: [SunSegment] = []

        func walk(_ node: FileNode, depth: Int, start: Double, end: Double, hue: Double) {
            guard depth < maxDepth, node.size > 0 else { return }
            let span = end - start
            var angle = start
            var drawn: Int64 = 0
            for child in node.children {
                let sweep = span * Double(child.size) / Double(node.size)
                if sweep < minAngle { break }
                let childHue = depth == 0 ? (angle + sweep / 2) / (2 * .pi) : hue
                segments.append(SunSegment(id: segments.count, node: child, owner: node, depth: depth,
                                           start: angle, end: angle + sweep, hue: childHue, size: child.size))
                drawn += child.size
                if child.isDirectory {
                    walk(child, depth: depth + 1, start: angle, end: angle + sweep, hue: childHue)
                }
                angle += sweep
            }
            if end - angle > minAngle {
                segments.append(SunSegment(id: segments.count, node: nil, owner: node, depth: depth,
                                           start: angle, end: end, hue: hue, size: node.size - drawn))
            }
        }

        walk(focus, depth: 0, start: 0, end: 2 * .pi, hue: 0)
        return segments
    }

    static func color(for segment: SunSegment, highlighted: Bool) -> Color {
        guard segment.node != nil else {
            return Color.gray.opacity(highlighted ? 0.55 : 0.3)
        }
        let depth = Double(segment.depth)
        var saturation = max(0.28, 0.66 - depth * 0.07)
        var brightness = min(1, 0.82 + depth * 0.03)
        if segment.isFile { saturation *= 0.4 }
        if highlighted {
            saturation = min(1, saturation + 0.2)
            brightness = 1
        }
        return Color(hue: segment.hue, saturation: saturation, brightness: brightness)
    }
}

struct SunburstView: View {
    let segments: [SunSegment]
    let focus: FileNode
    @Binding var hoveredID: Int?
    let onSelect: (SunSegment) -> Void
    let onCenter: () -> Void

    private struct Geometry {
        let center: CGPoint
        let outer: Double
        let inner: Double
        var ring: Double { (outer - inner) / Double(SunburstLayout.maxDepth) }
    }

    private func geometry(in size: CGSize) -> Geometry {
        let radius = max(40, min(size.width, size.height) / 2 - 12)
        return Geometry(center: CGPoint(x: size.width / 2, y: size.height / 2), outer: radius, inner: radius * 0.24)
    }

    var body: some View {
        GeometryReader { proxy in
            let geo = geometry(in: proxy.size)
            ZStack {
                Canvas { context, _ in
                    let separator = Color(nsColor: .windowBackgroundColor)
                    for segment in segments {
                        let r1 = geo.inner + Double(segment.depth) * geo.ring + 1
                        let path = sector(center: geo.center, r1: r1, r2: r1 + geo.ring - 1,
                                          a0: segment.start, a1: segment.end)
                        context.fill(path, with: .color(SunburstLayout.color(for: segment, highlighted: segment.id == hoveredID)))
                        context.stroke(path, with: .color(separator), lineWidth: 0.7)
                    }
                    let hub = CGRect(x: geo.center.x - geo.inner + 2, y: geo.center.y - geo.inner + 2,
                                     width: (geo.inner - 2) * 2, height: (geo.inner - 2) * 2)
                    context.fill(Path(ellipseIn: hub), with: .color(Color(nsColor: .controlBackgroundColor)))
                    context.stroke(Path(ellipseIn: hub), with: .color(Color.secondary.opacity(0.25)), lineWidth: 1)
                }
                centerLabel
                    .frame(width: geo.inner * 1.6)
                    .position(geo.center)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let id = hitTest(point, geo: geo)?.id
                    if id != hoveredID { hoveredID = id }
                case .ended:
                    hoveredID = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                let dx = point.x - geo.center.x
                let dy = point.y - geo.center.y
                if hypot(dx, dy) < geo.inner {
                    onCenter()
                } else if let segment = hitTest(point, geo: geo) {
                    onSelect(segment)
                }
            }
        }
    }

    private var hovered: SunSegment? {
        guard let hoveredID, hoveredID < segments.count else { return nil }
        return segments[hoveredID]
    }

    @ViewBuilder
    private var centerLabel: some View {
        VStack(spacing: 3) {
            if let hovered {
                Text(hovered.node?.name ?? "Мелкие объекты")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(Fmt.bytes(hovered.size))
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                if focus.size > 0 {
                    Text(String(format: "%.1f%%", Double(hovered.size) / Double(focus.size) * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(focus.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(Fmt.bytes(focus.size))
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                if focus.parent != nil {
                    Label("Назад", systemImage: "arrow.up.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func hitTest(_ point: CGPoint, geo: Geometry) -> SunSegment? {
        let dx = point.x - geo.center.x
        let dy = point.y - geo.center.y
        let radius = hypot(dx, dy)
        guard radius >= geo.inner, radius <= geo.outer else { return nil }
        let depth = Int((radius - geo.inner) / geo.ring)
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        return segments.first { $0.depth == depth && angle >= $0.start && angle < $0.end }
    }

    /// Кольцевой сектор. Углы отсчитываются от «12 часов» по часовой стрелке.
    private func sector(center: CGPoint, r1: Double, r2: Double, a0: Double, a1: Double) -> Path {
        var path = Path()
        let steps = max(2, Int((a1 - a0) / 0.03) + 1)
        func point(_ r: Double, _ a: Double) -> CGPoint {
            let t = a - .pi / 2
            return CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t))
        }
        for i in 0...steps {
            let a = a0 + (a1 - a0) * Double(i) / Double(steps)
            if i == 0 { path.move(to: point(r2, a)) } else { path.addLine(to: point(r2, a)) }
        }
        for i in stride(from: steps, through: 0, by: -1) {
            path.addLine(to: point(r1, a0 + (a1 - a0) * Double(i) / Double(steps)))
        }
        path.closeSubpath()
        return path
    }
}
