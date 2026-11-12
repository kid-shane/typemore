import AppKit
import SwiftUI

/// 设置与浮层共用中性色；跟随系统外观，避免两套视觉语言。
enum UITheme {
    static let background = adaptive(light: 0xFFFFFF, dark: 0x303030)
    static let sidebar = adaptive(light: 0xF5F5F4, dark: 0x383838)
    static let field = adaptive(light: 0xFAFAF9, dark: 0x363636)
    static let selection = adaptive(light: 0xE9E9E8, dark: 0x484848)
    static let text = adaptive(light: 0x242424, dark: 0xF1F1F1)
    static let secondary = adaptive(light: 0x6D6D70, dark: 0xB6B6B8)
    static let border = adaptive(light: 0xE4E4E3, dark: 0x4A4A4A)
    static let accent = adaptive(light: 0x3D63DD, dark: 0x91ABFF)
    static let success = adaptive(light: 0x26734D, dark: 0x83CEA1)
    static let error = adaptive(light: 0xBF3D36, dark: 0xFFA49E)

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            color(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct SettingsButtonStyle: ButtonStyle {
    var primary = false
    var minimumWidth: CGFloat = 0
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(primary ? UITheme.background : UITheme.text)
            .padding(.horizontal, 12)
            .frame(minWidth: minimumWidth)
            .frame(height: 34)
            .background(primary ? UITheme.text : UITheme.field)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(primary ? Color.clear : UITheme.border, lineWidth: 1)
            )
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
    }
}

/// 让阴影留在透明窗口内部，避免无边框面板裁掉阴影。
struct FloatingSurface: ViewModifier {
    var cornerRadius: CGFloat = 18
    var shadowPadding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(UITheme.background)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(UITheme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .padding(shadowPadding)
    }
}

@MainActor
enum FloatingPanelPosition {
    static func bottomCenter(_ panel: NSPanel, on placementScreen: NSScreen? = nil, bottomInset: CGFloat = 24) {
        let screen = placementScreen
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + bottomInset))
    }
}
