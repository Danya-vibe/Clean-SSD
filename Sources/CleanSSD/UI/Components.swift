import SwiftUI

struct TriCheckbox: View {
    let state: CheckState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch state {
        case .on: return "checkmark.square.fill"
        case .mixed: return "minus.square.fill"
        case .off: return "square"
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct ItemIcon: View {
    let appPath: String?
    let fallbackPath: String
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: appPath ?? fallbackPath))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct FullDiskAccessBanner: View {
    let onRecheck: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Нет полного доступа к диску").font(.headline)
                Text("Кэш Safari, Почты, изолированных приложений и Корзина не будут найдены. Добавьте Clean SSD в «Системные настройки → Конфиденциальность и безопасность → Полный доступ к диску» и перезапустите приложение.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer()
            Button("Открыть настройки") { Permissions.openFullDiskAccessSettings() }
            Button("Проверить", action: onRecheck)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
    }
}

struct SizeBar: View {
    let fraction: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                Capsule().fill(color.opacity(0.75))
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}
