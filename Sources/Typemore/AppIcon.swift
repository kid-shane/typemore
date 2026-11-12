import SwiftUI

/// 所有业务图标使用设置页的 SF Symbols 单色线性体系。
/// 固定画布与字重，避免 Label、按钮和浮层各自继承不同的字体。
enum AppSymbol: String, CaseIterable {
    case general = "slider.horizontal.3"
    case writing = "text.alignleft"
    case model = "cpu"
    case permissions = "lock.shield"
    case info = "info.circle"
    case keyboard
    case rewrite = "wand.and.stars"
    case next = "chevron.right"
    case expand = "chevron.down"
    case text = "textformat"
    case defaultStyle = "text.badge.checkmark"
    case customStyle = "pencil.line"
    case edit = "square.and.pencil"
    case connected = "checkmark.circle"
    case idle = "circle"
    case network
    case thinking = "sparkle"
    case warning = "exclamationmark.circle"
    case close = "xmark"
    case undo = "arrow.uturn.backward"
    case refresh = "arrow.clockwise"
    case search = "magnifyingglass"
    case check = "checkmark"
}

enum AppIconSize {
    case small, regular, large
    var points: CGFloat {
        switch self {
        case .small: return 12
        case .regular: return 16
        case .large: return 20
        }
    }
    var canvas: CGFloat { points + 4 }
}

struct AppIcon: View {
    let symbol: AppSymbol
    var size: AppIconSize = .regular

    var body: some View {
        Image(systemName: symbol.rawValue)
            .font(.system(size: size.points, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .frame(width: size.canvas, height: size.canvas)
            .accessibilityHidden(true)
    }
}

struct AppIconLabel: View {
    let title: String
    let symbol: AppSymbol
    var size: AppIconSize = .regular

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(symbol: symbol, size: size)
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 设置页、状态浮层与 Dock 共用 T+ 品牌标记，不使用旧绿色渐变。
struct TypemoreMark: View {
    var size: CGFloat = 30
    var badge = true

    var body: some View {
        Text("T+")
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .frame(width: size, height: size)
            .background(badge ? UITheme.text : Color.clear)
            .foregroundStyle(badge ? UITheme.background : UITheme.secondary)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.267))
            .accessibilityHidden(true)
    }
}
