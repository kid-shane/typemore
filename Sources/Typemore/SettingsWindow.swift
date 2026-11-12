import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: SettingsStore
    private let triggerController: RewriteTriggerCoordinator
    private let recorder = ChordRecorder()
    private var recordingObservation: AnyCancellable?
    private var window: NSWindow?

    init(store: SettingsStore, triggerController: RewriteTriggerCoordinator) {
        self.store = store
        self.triggerController = triggerController
        super.init()
        observeRecording()
    }

    private func observeRecording() {
        recordingObservation = recorder.$isRecording.removeDuplicates().dropFirst().sink { [weak self] recording in
            guard let self else { return }
            if recording { self.triggerController.pause() }
            else { self.triggerController.resume() }
        }
    }

    func show() { show(initialPage: .general) }

    func showAbout() {
        recorder.cancel()
        let hadWindow = window != nil
        show(initialPage: .about)
        if hadWindow {
            NotificationCenter.default.post(name: .typemoreOpenAbout, object: recorder)
        }
    }

    private func show(initialPage: SettingsPage) {
        if window == nil {
            let root = SettingsView(store: store, recorder: recorder, initialPage: initialPage)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Typemore"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.backgroundColor = .windowBackgroundColor
            window.minSize = NSSize(width: 760, height: 560)
            window.contentView = NSHostingView(rootView: root)
            window.isReleasedWhenClosed = false
            window.delegate = self
            if !window.setFrameUsingName("TypemoreSettings") { window.center() }
            window.setFrameAutosaveName("TypemoreSettings")
            self.window = window
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { recorder.cancel() }
    func windowDidResignKey(_ notification: Notification) { recorder.cancel() }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, writing, service, permissions, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "通用"
        case .writing: return "表达风格"
        case .service: return "模型服务"
        case .permissions: return "权限与隐私"
        case .about: return "关于"
        }
    }
    var icon: AppSymbol {
        switch self {
        case .general: return .general
        case .writing: return .writing
        case .service: return .model
        case .permissions: return .permissions
        case .about: return .info
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var recorder: ChordRecorder
    @State private var draft: AppSettings
    @State private var draftAPIKeys: [String: String]
    @State private var originalAPIKeys: [String: String]
    @State private var page: SettingsPage
    @State private var status = ""
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var statusGeneration = 0
    @State private var recordingPreviousTrigger: RewriteTrigger?
    @State private var rememberedChord: TriggerChord?
    @StateObject private var rewritePractice = RewritePracticeModel()
    @StateObject private var modelConnectionController = ModelConnectionController()
    @State private var modelServiceDialog: ModelServiceDialog?

    init(store: SettingsStore, recorder: ChordRecorder,
         initialPage: SettingsPage = .general) {
        self.store = store
        self.recorder = recorder
        _page = State(initialValue: initialPage)
        _draft = State(initialValue: store.settings)
        // 仅缓存当前服务已加载的 Key；切换服务时再按需读取钥匙串。
        _draftAPIKeys = State(initialValue: store.settings.provider.requiresAPIKey
            ? [store.settings.credentialAccount: store.settings.apiKey] : [:])
        _originalAPIKeys = State(initialValue: store.settings.provider.requiresAPIKey
            ? [store.settings.credentialAccount: store.settings.apiKey] : [:])
        if case .chord(let chord) = store.settings.rewriteTrigger {
            _rememberedChord = State(initialValue: chord)
        }
    }


    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(UITheme.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(page.title)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(UITheme.text)
                    .padding(.horizontal, 36)
                    .padding(.top, 42)
                    .padding(.bottom, 28)
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        switch page {
                        case .general: generalPage
                        case .writing: writingPage
                        case .service: servicePage
                        case .permissions: permissionsPage
                        case .about: AboutView()
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if page != .about { footer }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(UITheme.background)
        }
        .ignoresSafeArea()
        .tint(UITheme.accent)
        .disabled(modelServiceDialog != nil)
        .accessibilityHidden(modelServiceDialog != nil)
        .overlay {
            if page == .service { modelService.dialogOverlay }
        }
        .onAppear {
            normalizeProviderSelectionIfNeeded()
            refreshPermissionStatus()
            recorder.onFinish = { chord in
                if let chord {
                    draft.rewriteTrigger = .chord(chord)
                    rememberedChord = chord
                } else if let previous = recordingPreviousTrigger {
                    draft.rewriteTrigger = previous
                }
                recordingPreviousTrigger = nil
            }
        }
        .onChange(of: page) { _ in
            modelServiceDialog = nil
            recorder.cancel()
            refreshPermissionStatus()
        }
        .task(id: page) {
            guard page == .permissions else { return }
            while !Task.isCancelled {
                refreshPermissionStatus()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .typemoreOpenAbout, object: recorder)) { _ in
            page = .about
        }
        .onReceive(store.$settings) { saved in
            draft = saved
            if saved.provider.requiresAPIKey {
                draftAPIKeys[saved.credentialAccount] = saved.apiKey
                originalAPIKeys[saved.credentialAccount] = saved.apiKey
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 9) {
                TypemoreMark()
                Text("Typemore").font(.system(size: 17, weight: .semibold))
            }
            .padding(.horizontal, 14)
            VStack(spacing: 4) {
                ForEach(SettingsPage.allCases.filter { $0 != .about }) { item in
                    navigationButton(item)
                }
            }
            Spacer()
            navigationButton(.about)
        }
        .padding(.horizontal, 12)
        .padding(.top, 48)
        .padding(.bottom, 22)
        .frame(width: 188)
        .frame(maxHeight: .infinity)
        .background(UITheme.sidebar)
        .foregroundStyle(UITheme.text)
    }

    private func navigationButton(_ item: SettingsPage) -> some View {
        Button { page = item } label: {
            HStack(spacing: 10) {
                AppIcon(symbol: item.icon)
                Text(item.title)
                Spacer(minLength: 4)
                if item == .about {
                    Text(AboutMetadata().sidebarVersion)
                        .font(.system(size: 10))
                        .foregroundStyle(UITheme.secondary)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 13, weight: page == item ? .medium : .regular))
            .foregroundStyle(page == item ? UITheme.text : UITheme.secondary)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(page == item ? UITheme.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(page == item ? .isSelected : [])
    }

    @ViewBuilder private var generalPage: some View {
        SettingsSection("快捷键", icon: .keyboard) {
            SettingsRow("润色快捷键") {
                HStack(spacing: 2) {
                    triggerOption("双击右 Option", custom: false)
                    triggerOption("组合快捷键", custom: true)
                }
                .padding(3)
                .frame(width: 280)
                .background(UITheme.field)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(UITheme.border, lineWidth: 1))
            }
            if isChordSelected {
                SettingsRow("组合键") {
                    Button {
                        if recorder.isRecording { recorder.cancel() }
                        else { startChordRecording() }
                    } label: {
                        HStack(spacing: 8) {
                            AppIcon(symbol: .keyboard)
                            Text(recorder.isRecording ? chordPreview : draft.rewriteTrigger.displayText)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(recorder.isRecording ? "取消" : "重新录制")
                                .font(.system(size: 11))
                                .foregroundStyle(UITheme.secondary)
                        }
                        .frame(width: 256)
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(recorder.isRecording ? UITheme.accent : Color.clear, lineWidth: 1))
                    .accessibilityLabel(recorder.isRecording ? "取消录制" : "录制快捷键")
                }
                if let error = recorder.errorHint {
                    Text(error).font(.system(size: 12)).foregroundStyle(UITheme.error)
                } else if recorder.isRecording {
                    Text("按下组合键 · Esc 取消").font(.system(size: 12)).foregroundStyle(UITheme.secondary)
                }
            }
        }
        SettingsSection("使用", icon: .rewrite) {
            RewritePracticeView(
                model: rewritePractice,
                trigger: store.settings.rewriteTrigger,
                isRecording: recorder.isRecording
            )
        }
    }

    @ViewBuilder private var writingPage: some View {
        HStack(spacing: 12) {
            styleOption("默认表达", mode: .clear, icon: .defaultStyle)
            styleOption("自定义表达", mode: .custom, icon: .customStyle)
        }
        if draft.defaultMode == .custom {
            SettingsSection("表达偏好", icon: .edit) {
                ZStack(alignment: .topLeading) {
                    if draft.customStyle.isEmpty {
                        Text("例如：自然简洁，先说结论，适当分点。")
                            .foregroundStyle(UITheme.secondary)
                            .padding(12)
                    }
                    TextEditor(text: $draft.customStyle)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .accessibilityLabel("表达偏好")
                }
                .font(.system(size: 13))
                .foregroundStyle(UITheme.text)
                .frame(minHeight: 240)
                .background(UITheme.field)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(UITheme.border, lineWidth: 1))
            }
        }
    }

    private func styleOption(_ title: String, mode: RewriteMode, icon: AppSymbol) -> some View {
        Button { draft.defaultMode = mode } label: {
            HStack(spacing: 10) {
                AppIcon(symbol: icon)
                Text(title)
                Spacer()
                AppIcon(symbol: draft.defaultMode == mode ? .connected : .idle)
                    .foregroundStyle(draft.defaultMode == mode ? UITheme.accent : UITheme.secondary)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(UITheme.text)
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(draft.defaultMode == mode ? UITheme.selection : UITheme.field)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(UITheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(draft.defaultMode == mode ? .isSelected : [])
    }

    @ViewBuilder private var servicePage: some View {
        modelService
    }

    private var modelService: ModelServiceView {
        ModelServiceView(draft: $draft, apiKeys: $draftAPIKeys, store: store,
                         controller: modelConnectionController, dialog: $modelServiceDialog)
    }


    @ViewBuilder private var permissionsPage: some View {
        SettingsSection("系统权限", icon: .permissions) {
            permissionRow("辅助功能", granted: accessibilityGranted) { SystemTextService().openAccessibilitySettings() }
            permissionRow("输入监控", granted: inputMonitoringGranted) { SystemTextService().openInputMonitoringSettings() }
        }
        SettingsSection("数据与信息安全", icon: .info) {
            VStack(alignment: .leading, spacing: 12) {
                Text("仅在触发润色时读取目标文字与必要上下文，并发送到你选择的模型服务。")
                Text("不存储账号密码；API Key 保存在本机钥匙串。诊断日志不记录待润色正文。")
                Text("豆包 CLI 会按豆包的规则保存任务会话；请在豆包中管理相关记录。")
                Text("复制与粘贴后恢复剪贴板。第三方剪贴板工具可能记录中间内容。")
            }
            .font(.system(size: 12))
            .foregroundStyle(UITheme.secondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        SettingsRow(title) {
            HStack(spacing: 12) {
                AppIconLabel(title: granted ? "已开启" : "未开启",
                    symbol: granted ? .connected : .idle, size: .small)
                    .font(.system(size: 12))
                    .foregroundStyle(granted ? UITheme.success : UITheme.secondary)
                Button(granted ? "管理权限" : "开启权限", action: action)
                    .buttonStyle(SettingsButtonStyle())
                    .accessibilityLabel("打开\(title)设置")
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(UITheme.border).frame(height: 1)
            HStack(spacing: 12) {
                Button("恢复默认") { resetDraft() }
                    .buttonStyle(.plain)
                    .foregroundStyle(UITheme.secondary)
                Spacer(minLength: 8)
                if !status.isEmpty {
                    Text(status)
                        .foregroundStyle(status == "已保存" ? UITheme.success : UITheme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if hasChanges {
                    Button("取消") { discardDraft() }
                        .buttonStyle(SettingsButtonStyle(minimumWidth: 84))
                }
                Button("保存") { save() }
                    .buttonStyle(SettingsButtonStyle(primary: true, minimumWidth: 84))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!hasChanges || invalidChord || recorder.isRecording)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 36)
            .padding(.vertical, 18)
        }
    }

    private var hasChanges: Bool {
        draft != store.settings || draftAPIKeys.contains { provider, key in key != originalAPIKeys[provider] }
    }
    private var isChordSelected: Bool {
        if case .chord = draft.rewriteTrigger { return true }
        return false
    }
    private var invalidChord: Bool {
        if case .chord(let chord) = draft.rewriteTrigger { return !chord.hasModifier }
        return false
    }
    private var chordPreview: String {
        let symbols = recorder.liveModifiers.map(\.symbol).joined()
        return symbols.isEmpty ? "按下组合键…" : "\(symbols)…"
    }
    private func triggerOption(_ title: String, custom: Bool) -> some View {
        Button {
            guard custom != isChordSelected else { return }
            recorder.cancel()
            if custom { startChordRecording() }
            else { draft.rewriteTrigger = .doubleTapRightOption }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(custom == isChordSelected ? UITheme.text : UITheme.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(custom == isChordSelected ? UITheme.selection : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(custom == isChordSelected ? .isSelected : [])
    }

    private func startChordRecording() {
        recordingPreviousTrigger = draft.rewriteTrigger
        draft.rewriteTrigger = rememberedChord.map(RewriteTrigger.chord)
            ?? .chord(TriggerChord(modifiers: [], keyCode: 0, keyLabel: ""))
        recorder.start()
    }
    private var providerSelection: Binding<Provider> {
        Binding(get: { draft.provider }, set: { switchProvider(to: $0) })
    }

    private func refreshPermissionStatus() {
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
    }

    private func save() {
        guard !invalidChord, !recorder.isRecording else { return }
        do {
            rememberDraftAPIKey(for: draft.provider)
            try store.save(draft, apiKeys: draftAPIKeys)
            originalAPIKeys = draftAPIKeys
            statusGeneration += 1
            let generation = statusGeneration
            status = "已保存"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                if statusGeneration == generation { status = "" }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func discardDraft() {
        recorder.cancel()
        draft = store.settings
        draftAPIKeys = draft.provider.requiresAPIKey ? [draft.credentialAccount: draft.apiKey] : [:]
        originalAPIKeys = draftAPIKeys
        statusGeneration += 1
        status = ""
    }

    private func resetDraft() {
        recorder.cancel()
        draft.rememberConnection()
        let current = draft
        draft = AppSettings.defaults
        draft.connections = current.connections
        if let connection = current.connections.first(where: { $0.id == current.activeConnectionID }) {
            draft.selectConnection(connection, key: current.apiKey)
        }
        statusGeneration += 1
        status = ""
    }

    private func normalizeProviderSelectionIfNeeded() {
        draft.ensureConnection()
    }

    private func switchProvider(to provider: Provider) {
        guard provider != draft.provider else { return }
        rememberDraftAPIKey(for: draft.provider)
        draft.addConnection(provider)
    }

    private func rememberDraftAPIKey(for provider: Provider) {
        if provider.requiresAPIKey { draftAPIKeys[draft.credentialAccount] = draft.apiKey }
    }


}

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: AppSymbol
    @ViewBuilder let content: Content

    init(_ title: String, icon: AppSymbol, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppIconLabel(title: title, symbol: icon, size: .small)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(UITheme.secondary)
            Rectangle().fill(UITheme.border).frame(height: 1)
            content
        }
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 8)
            content
        }
        .foregroundStyle(UITheme.text)
        .frame(minHeight: 38)
    }
}

private struct SettingsTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var secure = false

    var body: some View {
        SettingsRow(title) {
            Group {
                if secure { SecureField(placeholder, text: $text) }
                else { TextField(placeholder, text: $text) }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(width: 280, height: 34)
            .background(UITheme.field)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(UITheme.border, lineWidth: 1))
            .accessibilityLabel(title)
        }
    }
}
