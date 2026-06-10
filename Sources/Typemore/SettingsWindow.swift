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
    @State private var draftAPIKeys: [Provider: String]
    @State private var status = ""
    @State private var selectedStyle: StyleTab
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false

    init(store: SettingsStore) {
        self.store = store
        _draft = State(initialValue: store.settings)
        _draftAPIKeys = State(initialValue: Self.loadDraftAPIKeys(current: store.settings))
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
        .onAppear {
            normalizeProviderSelectionIfNeeded()
            refreshPermissionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
        .onReceive(store.$settings) { settings in
            draft = settings
            draftAPIKeys[settings.provider] = settings.apiKey
        }
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
            VStack(alignment: .leading, spacing: 14) {
                ServiceTypeSelector(selection: providerSelection)
                if draft.provider == .volcengine {
                    VolcengineEndpointSelector(selection: $draft.volcengineEndpointKind)
                        .onChange(of: draft.volcengineEndpointKind) { kind in
                            applyVolcengineEndpointDefaults(kind)
                        }
                }
                Text(providerHelpText)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.secondaryText)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 102)
                SettingsField(title: "Base URL", text: $draft.endpoint, placeholder: providerEndpointPlaceholder)
                SettingsField(title: "Model", text: $draft.model, placeholder: providerModelPlaceholder)
                SettingsField(title: "API Key", text: $draft.apiKey, placeholder: "sk-...", isSecure: true)
                thinkingModeRow
            }
        }
    }

    private var providerHelpText: String {
        switch draft.provider {
        case .volcengine:
            return draft.volcengineEndpointKind == .api
                ? "适合直接使用火山方舟 API 的用户。"
                : "适合使用火山方舟 Coding Plan / AI 工具兼容入口的用户。"
        case .compatible:
            return "适合 DeepSeek、OpenRouter、Moonshot、硅基流动等支持 OpenAI 兼容接口的服务。"
        case .demo, .openai:
            return ""
        }
    }

    private var providerEndpointPlaceholder: String {
        switch draft.provider {
        case .volcengine:
            return draft.volcengineEndpointKind.defaultEndpoint
        case .compatible:
            return "例如 https://api.deepseek.com"
        case .demo, .openai:
            return "https://..."
        }
    }

    private var providerModelPlaceholder: String {
        switch draft.provider {
        case .volcengine:
            return Provider.volcengine.defaultModel
        case .compatible:
            return "例如 deepseek-chat"
        case .demo, .openai:
            return "model name"
        }
    }

    private var thinkingModeRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("思考模式")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsTheme.secondaryText)
                .frame(width: 88, alignment: .leading)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                ThinkingModeToggle(isOn: $draft.thinkingEnabled)
                Text("建议默认关闭。开启后模型可能会进入推理流程，改写时间可能变长，部分服务可能需要 30 秒以上。")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                if hasMissingPermission {
                    permissionRepairTip
                }
            }
        }
    }

    private var hasMissingPermission: Bool {
        !accessibilityGranted || !inputMonitoringGranted
    }

    private var permissionRepairTip: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lightbulb")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsTheme.green.opacity(0.95))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text("如果这里显示未开启，但你已经在 macOS 里打开过")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primaryText)
                Text("请按这几步修复：1. 点下方对应权限的「打开」；2. 在「系统设置 > 隐私与安全性 > 辅助功能/输入监控」里，先把 Typemore 从列表中移除，再重新添加并打开；3. 完全退出 Typemore 后重新打开。")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("刷新状态") {
                    refreshPermissionStatus()
                }
                .buttonStyle(InlineSettingsButtonStyle())
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsTheme.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SettingsTheme.green.opacity(0.16), lineWidth: 1)
        )
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
            if ![Provider.volcengine, .compatible].contains(draft.provider) {
                draft.provider = .compatible
            }
            rememberDraftAPIKey(for: draft.provider)
            persistDraftAPIKeys()
            draft.serviceName = draft.provider.displayName
            draft.defaultMode = selectedStyle == .custom ? .custom : .clear
            if draft.serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.serviceName = draft.provider.displayName
            }
            if draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.endpoint = draft.provider == .volcengine ? draft.volcengineEndpointKind.defaultEndpoint : draft.provider.defaultEndpoint
            }
            if draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.model = draft.provider.defaultModel
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
        KeychainStore.deleteAllAPIKeys()
        draftAPIKeys = [:]
        draft = AppSettings.defaults
        selectedStyle = .default
        save()
    }

    private func normalizeProviderSelectionIfNeeded() {
        guard ![Provider.volcengine, .compatible].contains(draft.provider) else { return }
        draft.provider = .compatible
        draft.serviceName = Provider.compatible.displayName
        draft.apiKey = apiKey(for: .compatible)
    }

    private static func loadDraftAPIKeys(current settings: AppSettings) -> [Provider: String] {
        var keys: [Provider: String] = [:]
        for provider in [Provider.volcengine, .compatible] {
            keys[provider] = KeychainStore.loadAPIKey(for: provider)
        }
        keys[settings.provider] = settings.apiKey
        return keys
    }

    private var providerSelection: Binding<Provider> {
        Binding(
            get: { draft.provider },
            set: { switchProvider(to: $0) }
        )
    }

    private func switchProvider(to provider: Provider) {
        guard provider != draft.provider else { return }
        rememberDraftAPIKey(for: draft.provider)
        draft.provider = provider
        draft.apiKey = apiKey(for: provider)
        applyProviderDefaults(provider)
    }

    private func rememberDraftAPIKey(for provider: Provider) {
        guard [Provider.volcengine, .compatible].contains(provider) else { return }
        draftAPIKeys[provider] = draft.apiKey
    }

    private func persistDraftAPIKeys() {
        for provider in [Provider.volcengine, .compatible] {
            KeychainStore.saveAPIKey(draftAPIKeys[provider] ?? "", for: provider)
        }
    }

    private func apiKey(for provider: Provider) -> String {
        if let cached = draftAPIKeys[provider] {
            return cached
        }
        return KeychainStore.loadAPIKey(for: provider)
    }

    private func applyProviderDefaults(_ provider: Provider) {
        draft.serviceName = provider.displayName
        draft.endpoint = provider == .volcengine ? draft.volcengineEndpointKind.defaultEndpoint : provider.defaultEndpoint
        draft.model = provider.defaultModel
    }

    private func applyVolcengineEndpointDefaults(_ kind: VolcengineEndpointKind) {
        draft.endpoint = kind.defaultEndpoint
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

private struct ServiceTypeSelector: View {
    @Binding var selection: Provider

    private let options: [Provider] = [.volcengine, .compatible]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("服务类型")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsTheme.secondaryText)
            HStack(spacing: 8) {
                ForEach(options) { provider in
                    SegmentButton(
                        title: provider.displayName,
                        isSelected: selection == provider
                    ) {
                        selection = provider
                    }
                }
            }
        }
    }
}

private struct VolcengineEndpointSelector: View {
    @Binding var selection: VolcengineEndpointKind
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("接入方式")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsTheme.secondaryText)
                .frame(width: 88, alignment: .leading)
                .padding(.top, 9)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Text(selection.displayName)
                            .font(.system(size: 13))
                            .foregroundColor(SettingsTheme.primaryText)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SettingsTheme.secondaryText)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(SettingsTheme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(SettingsTheme.stroke, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(spacing: 0) {
                        ForEach(VolcengineEndpointKind.allCases) { kind in
                            Button {
                                selection = kind
                                withAnimation(.easeOut(duration: 0.12)) { isExpanded = false }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(kind.displayName)
                                        .font(.system(size: 13))
                                        .foregroundColor(SettingsTheme.primaryText)
                                    Spacer(minLength: 0)
                                    if kind == selection {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(SettingsTheme.green)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity)
                                .frame(height: 32)
                                .background(kind == selection ? SettingsTheme.green.opacity(0.08) : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    .background(SettingsTheme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(SettingsTheme.stroke, lineWidth: 1)
                    )
                }
            }
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

private struct ThinkingModeToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                isOn.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Text("开启思考/推理模式")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SettingsTheme.primaryText)
                Spacer(minLength: 0)
                Text(isOn ? "已开启" : "已关闭")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isOn ? SettingsTheme.green : SettingsTheme.secondaryText)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isOn ? SettingsTheme.green.opacity(0.95) : SettingsTheme.field)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(isOn ? SettingsTheme.green.opacity(0.65) : SettingsTheme.stroke, lineWidth: 1)
                        )
                    Circle()
                        .fill(isOn ? Color.black.opacity(0.78) : SettingsTheme.secondaryText)
                        .frame(width: 14, height: 14)
                        .padding(3)
                }
                .frame(width: 38, height: 20)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(SettingsTheme.field)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isOn ? SettingsTheme.green.opacity(0.28) : SettingsTheme.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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

private struct InlineSettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(SettingsTheme.green.opacity(configuration.isPressed ? 0.65 : 0.95))
    }
}
