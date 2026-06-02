import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let store: SettingsStore
    private var window: NSWindow?

    init(store: SettingsStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let rootView = SettingsView(store: store)
            let hosting = NSHostingView(rootView: rootView)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Typemore Settings"
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(red: 0.035, green: 0.043, blue: 0.039, alpha: 1)
            window.minSize = NSSize(width: 680, height: 620)
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var draft: AppSettings
    @State private var status = ""
    @State private var selectedStyle: StyleTab
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false

    init(store: SettingsStore) {
        self.store = store
        _draft = State(initialValue: store.settings)
        _selectedStyle = State(initialValue: store.settings.defaultMode == .custom ? .custom : .default)
    }

    var body: some View {
        ZStack {
            SettingsTheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                header
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        providerCard
                        writingCard
                        privacyCard
                    }
                    .padding(.bottom, 4)
                }
                footer
            }
            .padding(28)
        }
        .onAppear { refreshPermissionStatus() }
        .onReceive(store.$settings) { draft = $0 }
        .onReceive(store.$settings) { settings in
            selectedStyle = settings.defaultMode == .custom ? .custom : .default
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    TypemoreMark()
                    Text("Typemore")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(SettingsTheme.primaryText)
                }
                Text("Type more，让表达更丰富")
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsTheme.secondaryText)
            }
            Spacer()
        }
    }

    private var providerCard: some View {
        SettingsCard(title: "Model Service") {
            VStack(spacing: 14) {
                SettingsField(title: "服务名称", text: $draft.serviceName, placeholder: "火山方舟")
                SettingsField(title: "Base URL", text: $draft.endpoint, placeholder: "https://...")
                SettingsField(title: "Model", text: $draft.model, placeholder: "model name")
                SettingsField(title: "API Key", text: $draft.apiKey, placeholder: "sk-...", isSecure: true)
            }
        }
    }

    private var writingCard: some View {
        SettingsCard(title: "Writing Style") {
            VStack(spacing: 14) {
                StyleTabSelector(selection: $selectedStyle)
                    .onChange(of: selectedStyle) { tab in
                        draft.defaultMode = tab == .custom ? .custom : .clear
                    }
                if selectedStyle == .custom {
                    SettingsEditor(
                        title: "自定义风格",
                        text: $draft.customStyle,
                        minHeight: 116,
                        placeholder: "描述你希望 Typemore 遵循的表达风格。"
                    )
                } else {
                    DefaultStylePreview()
                }
            }
        }
    }

    private var privacyCard: some View {
        SettingsCard(title: "Privacy & Permissions") {
            VStack(alignment: .leading, spacing: 14) {
                PermissionRow(
                    title: "辅助功能",
                    granted: accessibilityGranted,
                    openAction: { SystemTextService().openAccessibilitySettings() }
                )
                PermissionRow(
                    title: "输入监控",
                    granted: inputMonitoringGranted,
                    openAction: { SystemTextService().openInputMonitoringSettings() }
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text("只在你双击右 Option 时读取文本。")
                    Text("目标文本和必要上下文会发送到你配置的模型服务。")
                    Text("部分应用会临时使用系统剪贴板，用完即恢复。")
                }
                .font(.system(size: 12))
                .foregroundStyle(SettingsTheme.secondaryText)
                .lineSpacing(2)
            }
        }
    }

    private func refreshPermissionStatus() {
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("保存设置") { save() }
                .buttonStyle(PrimarySettingsButtonStyle())
                .keyboardShortcut(.defaultAction)
            Button("恢复默认") { reset() }
                .buttonStyle(SecondarySettingsButtonStyle())
            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(status == "已保存" ? SettingsTheme.green : SettingsTheme.error)
                    .transition(.opacity)
            }
            Spacer()
        }
    }

    private func save() {
        do {
            draft.provider = .volcengine
            draft.defaultMode = selectedStyle == .custom ? .custom : .clear
            if draft.serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.serviceName = Provider.volcengine.displayName
            }
            if draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.endpoint = Provider.volcengine.defaultEndpoint
            }
            if draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.model = Provider.volcengine.defaultModel
            }
            try store.save(draft)
            status = "已保存"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                if status == "已保存" { status = "" }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func reset() {
        draft = AppSettings.defaults
        selectedStyle = .default
        save()
    }
}

private enum SettingsTheme {
    static let green = Color(red: 0.27, green: 0.96, blue: 0.61)
    static let error = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let primaryText = Color(red: 0.93, green: 0.98, blue: 0.95)
    static let secondaryText = Color(red: 0.58, green: 0.65, blue: 0.61)
    static let mutedText = Color(red: 0.42, green: 0.49, blue: 0.45)
    static let card = Color(red: 0.055, green: 0.071, blue: 0.064)
    static let field = Color(red: 0.028, green: 0.038, blue: 0.034)
    static let stroke = Color.white.opacity(0.08)

    static var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.032, green: 0.043, blue: 0.039),
                    Color(red: 0.014, green: 0.019, blue: 0.017)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(green.opacity(0.08))
                .frame(width: 360, height: 360)
                .blur(radius: 70)
                .offset(x: -280, y: -230)
            Circle()
                .fill(Color.white.opacity(0.035))
                .frame(width: 300, height: 300)
                .blur(radius: 70)
                .offset(x: 300, y: 250)
        }
    }
}

private enum StyleTab: String, CaseIterable, Identifiable {
    case `default`
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: return "默认风格"
        case .custom: return "自定义风格"
        }
    }
}

private struct TypemoreMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SettingsTheme.green.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(SettingsTheme.green.opacity(0.28), lineWidth: 1)
                )
            Text("T+")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(SettingsTheme.green)
        }
        .frame(width: 34, height: 34)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(SettingsTheme.primaryText)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SettingsTheme.card.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(SettingsTheme.stroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
    }
}

private struct SettingsField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var isSecure = false

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsTheme.secondaryText)
                .frame(width: 88, alignment: .leading)
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(SettingsTheme.primaryText)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(SettingsTheme.field)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(SettingsTheme.stroke, lineWidth: 1)
            )
        }
    }
}

private struct SettingsEditor: View {
    let title: String
    @Binding var text: String
    let minHeight: CGFloat
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsTheme.secondaryText)
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.mutedText)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                }
                TextEditor(text: $text)
                    .font(.system(size: 12))
                    .foregroundColor(SettingsTheme.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
            }
            .frame(minHeight: minHeight)
            .background(SettingsTheme.field)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(SettingsTheme.stroke, lineWidth: 1)
            )
        }
    }
}

private struct StyleTabSelector: View {
    @Binding var selection: StyleTab

    var body: some View {
        HStack(spacing: 8) {
            ForEach(StyleTab.allCases) { tab in
                SegmentButton(
                    title: tab.title,
                    isSelected: selection == tab
                ) {
                    selection = tab
                }
            }
        }
    }
}

private struct DefaultStylePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("默认风格")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsTheme.secondaryText)
            VStack(alignment: .leading, spacing: 7) {
                Text("适合日常表达和工作沟通：保留原意、事实和语气，把表达改得更清晰、自然、有条理。")
                Text("内容散乱时会主动理顺主线，突出结论、背景、问题、反馈、诉求或下一步。")
                Text("长内容或信息点较多时，会优先拆成短段、分点或编号，提升阅读效率。")
            }
            .font(.system(size: 13))
            .foregroundStyle(SettingsTheme.primaryText)
            .lineSpacing(3)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsTheme.field)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(SettingsTheme.stroke, lineWidth: 1)
            )
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let openAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsTheme.secondaryText)
                .frame(width: 88, alignment: .leading)
            HStack(spacing: 6) {
                Circle()
                    .fill(granted ? SettingsTheme.green : SettingsTheme.error)
                    .frame(width: 7, height: 7)
                Text(granted ? "已开启" : "未开启")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(granted ? SettingsTheme.green : SettingsTheme.error)
            }
            Spacer()
            Button("打开", action: openAction)
                .buttonStyle(SecondarySettingsButtonStyle())
        }
    }
}

private struct SegmentButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .foregroundStyle(isSelected ? Color.black.opacity(0.84) : SettingsTheme.secondaryText)
                .background(isSelected ? SettingsTheme.green : SettingsTheme.field)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? SettingsTheme.green.opacity(0.6) : SettingsTheme.stroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct PrimarySettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.84))
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(SettingsTheme.green.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct SecondarySettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(SettingsTheme.primaryText)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(SettingsTheme.field.opacity(configuration.isPressed ? 0.65 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(SettingsTheme.stroke, lineWidth: 1)
            )
    }
}
