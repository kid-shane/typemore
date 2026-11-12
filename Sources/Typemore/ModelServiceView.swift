import AppKit
import SwiftUI

@MainActor
final class ModelConnectionController: ObservableObject {
    @Published var models: [ServiceModel] = []
    @Published var message = ""
    @Published var result = ""
    @Published var email = ""
    @Published var qrImage: NSImage?
    @Published var busy = false
    @Published var failed = false
    private var task: Task<Void, Never>?
    func cancel() { task?.cancel(); task = nil; busy = false; qrImage = nil }
    func reset() { cancel(); models = []; message = ""; result = ""; email = ""; failed = false }
    func run(_ work: @escaping @MainActor () async throws -> Void) {
        cancel(); busy = true; failed = false; message = ""; result = ""
        task = Task {
            defer { if !Task.isCancelled { busy = false; qrImage = nil } }
            do { try await work() }
            catch is CancellationError { }
            catch { if !Task.isCancelled { failed = true; message = error.localizedDescription } }
        }
    }
    func showQR(_ output: String) {
        guard let expression = try? NSRegularExpression(pattern: #"(/[^\s\"']+\.png)"#),
              let match = expression.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return }
        let path = String(output[range])
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard resolved.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path) else { return }
        if let image = NSImage(contentsOfFile: resolved) { qrImage = image }
    }
}

enum ModelServiceDialog {
    case connections, add, models, account, remove, disconnect
}

struct ModelServiceView: View {
    @Binding var draft: AppSettings
    @Binding var apiKeys: [String: String]
    let store: SettingsStore
    @ObservedObject var controller: ModelConnectionController
    @Binding var dialog: ModelServiceDialog?
    @State private var advanced = false
    @State private var testing = false
    @State private var testText = "这个事情我们可以先试试看，然后再决定要不要继续。"

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection("连接", icon: .network) {
                SettingsRow("模型服务") {
                    Button { dialog = .connections } label: {
                        selectionLabel(connectionTitle(name: draft.serviceName, provider: draft.provider))
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .accessibilityLabel("切换模型连接")
                    .accessibilityValue(draft.serviceName)
                }
                if draft.provider == .chatgpt { chatGPTAccount }
                else if draft.provider == .doubao { doubaoAccount }
                else if draft.provider.requiresAPIKey { apiKeyRow }
                if draft.provider == .compatible || draft.provider == .ollama { endpointRow }
                if draft.provider == .openai {
                    Text("使用开发者 API，按 API 平台的额度与计费规则使用。")
                        .font(.system(size: 11)).foregroundStyle(UITheme.secondary)
                }
            }
            if draft.provider != .doubao {
                SettingsSection("模型", icon: .model) {
                    SettingsRow("当前模型") {
                        Button {
                            dialog = .models
                            if controller.models.isEmpty { fetchModels() }
                        } label: {
                            selectionLabel(modelSelectionTitle)
                        }
                        .buttonStyle(SettingsButtonStyle())
                        .disabled(controller.busy || needsCredential)
                        .accessibilityLabel("选择可用模型")
                        .accessibilityValue(modelSelectionTitle)
                    }
                    if draft.provider.supportsThinkingToggle { thinkingRow }
                }
            }
            utilities
            if !store.credentialError.isEmpty {
                status(store.credentialError, failed: true)
            }
            if controller.busy || !controller.message.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    if controller.busy { ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 14, height: 14) }
                    status(controller.message.isEmpty ? "正在连接…" : controller.message, failed: controller.failed)
                    Spacer(minLength: 0)
                    if controller.busy {
                        Button("停止") { controller.cancel(); controller.message = "已停止当前操作" }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(UITheme.secondary)
                    }
                }
            }
        }
        .onChange(of: draft.activeConnectionID) { _ in
            advanced = false; testing = false
            controller.reset(); loadIdentity()
        }
        .onChange(of: draft.endpoint) { _ in if draft.provider != .chatgpt { controller.reset() } }
        .onChange(of: draft.model) { _ in if !controller.busy { controller.result = "" } }
        .onChange(of: draft.apiKey) { _ in if draft.provider.requiresAPIKey { controller.reset() } }
        .onAppear { loadIdentity() }
        .onDisappear { controller.cancel(); dialog = nil }
    }

    private var needsCredential: Bool {
        (draft.provider.requiresAPIKey && draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || (draft.provider == .chatgpt && controller.email.isEmpty)
    }

    private var modelSelectionTitle: String {
        if needsCredential { return draft.provider == .chatgpt ? "先连接 ChatGPT" : "先填写 API Key" }
        return draft.model.isEmpty ? "选择模型" : draft.model
    }

    private func connectionTitle(name: String, provider: Provider) -> String {
        provider == .openai && name == "OpenAI" ? provider.displayName : name
    }

    private func selectionLabel(_ value: String) -> some View {
        HStack(spacing: 8) {
            Text(value).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            AppIcon(symbol: .expand, size: .small).foregroundStyle(UITheme.secondary)
        }.frame(width: 256, alignment: .leading)
    }

    private var chatGPTAccount: some View {
        SettingsRow("账号") {
            if controller.email.isEmpty {
                VStack(alignment: .trailing, spacing: 6) {
                    Button("连接 ChatGPT") { signIn() }
                        .buttonStyle(SettingsButtonStyle(primary: true)).disabled(controller.busy)
                    Text("账号登录 · 授权使用套餐").font(.system(size: 11)).foregroundStyle(UITheme.secondary)
                }
            } else {
                Button { dialog = .account } label: {
                    HStack(spacing: 8) {
                        Circle().fill(UITheme.success).frame(width: 6, height: 6)
                        Text(controller.email).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Image(systemName: "ellipsis").foregroundStyle(UITheme.secondary)
                    }.frame(width: 256)
                }
                .buttonStyle(SettingsButtonStyle())
                .accessibilityLabel("管理 ChatGPT 账号")
                .accessibilityValue(controller.email)
            }
        }
    }

    private var apiKeyRow: some View {
        VStack(alignment: .trailing, spacing: 8) {
            SettingsRow("API Key") {
                SecureField("粘贴你的 API Key", text: $draft.apiKey)
                    .modelInput().accessibilityLabel("模型 API Key")
            }
            if let url = draft.provider.keyURL {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text("获取 API Key")
                        Image(systemName: "arrow.up.right").font(.system(size: 9))
                    }
                }.font(.system(size: 11)).foregroundStyle(UITheme.secondary)
            }
        }
    }

    private var endpointRow: some View {
        SettingsRow("服务地址") {
            TextField("https://api.example.com/v1", text: $draft.endpoint)
                .modelInput().accessibilityLabel("模型服务地址")
        }
    }

    private var thinkingRow: some View {
        SettingsRow("深入思考") {
            Toggle("深入思考", isOn: $draft.thinkingEnabled)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel("深入思考")
        }
    }

    private var doubaoAccount: some View {
        VStack(alignment: .leading, spacing: 12) {
#if arch(x86_64)
            Text("豆包 CLI 当前支持 Apple Silicon。")
                .font(.system(size: 12)).foregroundStyle(UITheme.secondary)
#else
            SettingsRow("本机豆包 CLI") {
                HStack(spacing: 12) {
                    Text(DoubaoCLI.resolve(draft.cliPath) == nil ? "未安装" : "已检测到")
                        .font(.system(size: 12)).foregroundStyle(UITheme.secondary)
                    Spacer(minLength: 0)
                    Button("检测") { checkDoubao() }.buttonStyle(SettingsButtonStyle())
                    Button("扫码登录") { loginDoubao() }.buttonStyle(SettingsButtonStyle())
                }.frame(width: 280).disabled(controller.busy)
            }
            if let image = controller.qrImage {
                VStack(spacing: 8) {
                    Image(nsImage: image).resizable().interpolation(.none).scaledToFit().frame(width: 180, height: 180)
                        .accessibilityLabel("豆包登录二维码")
                    Text("使用豆包扫码，登录后自动继续。").font(.system(size: 12)).foregroundStyle(UITheme.secondary)
                }.frame(maxWidth: .infinity)
            }
#endif
            HStack {
                Spacer()
                Link("安装官方豆包 CLI ↗", destination: URL(string: "https://www.npmjs.com/package/@bytedance/doubao-cli")!)
                    .font(.system(size: 11)).foregroundStyle(UITheme.secondary)
            }
        }
    }

    private var utilities: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(UITheme.border).frame(height: 1)
            disclosure("高级设置", expanded: $advanced)
            if advanced {
                VStack(spacing: 14) {
                    SettingsRow("连接名称") {
                        TextField("为连接起个名字", text: $draft.serviceName).modelInput()
                    }
                    if draft.provider == .doubao {
                        SettingsRow("CLI 文件") {
                            Button {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url { draft.cliPath = url.path; controller.reset() }
                            } label: {
                                Text(draft.cliPath.isEmpty ? "自动检测 · 选择文件…" : URL(fileURLWithPath: draft.cliPath).lastPathComponent)
                                    .lineLimit(1).frame(width: 256, alignment: .leading)
                            }.buttonStyle(SettingsButtonStyle())
                        }
                        SettingsRow("模型") {
                            TextField("留空使用默认模型", text: $draft.model).modelInput().accessibilityLabel("豆包模型名称")
                        }
                        thinkingRow
                    } else {
                        if draft.provider != .chatgpt && draft.provider != .compatible && draft.provider != .ollama { endpointRow }
                        if draft.provider == .anthropic {
                            SettingsRow("工作区 ID") {
                                TextField("可选", text: $draft.workspaceID).modelInput()
                            }
                        }
                    }
                    if draft.provider.supportsThinkingToggle || draft.provider == .doubao {
                        Text("日常润色建议关闭深入思考，减少等待时间。")
                            .font(.system(size: 11)).foregroundStyle(UITheme.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 4).padding(.bottom, 20)
            }
            disclosure("测试连接", expanded: $testing)
            if testing { trial.padding(.top, 4).padding(.bottom, 12) }
        }
    }

    private func disclosure(_ title: String, expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .medium)).frame(width: 12)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(UITheme.secondary).frame(height: 40).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(expanded.wrappedValue ? "已展开" : "已收起")
    }

    private var trial: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("写一句想润色的话", text: $testText, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...4)
                .padding(12).background(UITheme.field).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(UITheme.border, lineWidth: 1))
                .accessibilityLabel("连接试用文本")
            HStack {
                Text("将发送这段文字，使用所选服务的额度。")
                    .font(.system(size: 11)).foregroundStyle(UITheme.secondary)
                Spacer(minLength: 8)
                Button("试用改写") { tryRewrite() }
                    .buttonStyle(SettingsButtonStyle(primary: true))
                    .disabled(controller.busy || needsCredential || (draft.provider != .doubao && draft.model.isEmpty)
                              || testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !controller.result.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("改写结果").font(.system(size: 11)).foregroundStyle(UITheme.secondary)
                    Text(controller.result).font(.system(size: 13)).textSelection(.enabled)
                        .accessibilityLabel("模型试用结果")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(UITheme.field).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func status(_ message: String, failed: Bool) -> some View {
        Text(message).font(.system(size: 12)).foregroundStyle(failed ? UITheme.error : UITheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder var dialogOverlay: some View {
        if let dialog {
            GeometryReader { geometry in
              ZStack {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { self.dialog = nil }
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(dialogTitle(dialog)).font(.system(size: 19, weight: .semibold))
                        Spacer()
                        Button { self.dialog = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28)
                        }
                        .buttonStyle(ModelOptionStyle())
                        .accessibilityLabel("关闭弹层").keyboardShortcut(.cancelAction)
                    }
                    switch dialog {
                    case .connections: connectionsDialog
                    case .add:
                        ScrollView { chooser }
                            .frame(height: min(500, max(250, geometry.size.height - 160)))
                    case .models:
                        ModelPickerContent(controller: controller, selection: $draft.model, dismiss: { self.dialog = nil },
                                           refresh: { fetchModels() })
                    case .account: accountDialog
                    case .remove, .disconnect: confirmationContent(dialog)
                    }
                }
                .foregroundStyle(UITheme.text).padding(24).frame(width: dialog == .add ? 496 : 448)
                .background(UITheme.background).clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(UITheme.border.opacity(0.7), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
                .padding(24)
              }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func dialogTitle(_ value: ModelServiceDialog) -> String {
        switch value {
        case .connections: return "模型连接"
        case .add: return "添加连接"
        case .models: return "选择模型"
        case .account: return "ChatGPT 账号"
        case .remove: return "移除这个连接？"
        case .disconnect: return "断开 ChatGPT？"
        }
    }

    private var connectionsDialog: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(draft.connections) { connection in
                        Button { select(connection); dialog = nil } label: {
                            HStack(spacing: 12) {
                                providerIcon(connection.provider)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(connectionTitle(name: connection.name, provider: connection.provider)).font(.system(size: 13, weight: .medium))
                                    Text(connection.provider == .chatgpt ? "账号登录 · 使用套餐" : connection.provider == .openai ? "API Key · API 平台计费" : connection.model.isEmpty ? (connection.provider == .doubao ? "本机 CLI" : "待选择模型") : connection.model)
                                        .font(.system(size: 11)).foregroundStyle(UITheme.secondary).lineLimit(1)
                                }
                                Spacer()
                                if connection.id == draft.activeConnectionID { AppIcon(symbol: .check, size: .small) }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(ModelOptionStyle(selected: connection.id == draft.activeConnectionID))
                        .accessibilityAddTraits(connection.id == draft.activeConnectionID ? .isSelected : [])
                    }
                }
            }.frame(height: min(CGFloat(draft.connections.count) * 61, 260))
            Rectangle().fill(UITheme.border).frame(height: 1).padding(.vertical, 4)
            HStack {
                Button { dialog = .add } label: { Label("添加连接", systemImage: "plus") }
                    .buttonStyle(SettingsButtonStyle())
                Spacer()
                Button("移除当前连接") { dialog = .remove }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(UITheme.secondary)
            }
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接已有账号").font(.system(size: 11, weight: .medium)).foregroundStyle(UITheme.secondary)
            VStack(spacing: 4) {
                connectionOption(.chatgpt, title: "ChatGPT 账号登录", subtitle: "授权使用 ChatGPT 套餐")
                connectionOption(.doubao, title: "豆包", subtitle: "通过本机官方 CLI 连接")
                connectionOption(.ollama, title: "Ollama", subtitle: "使用本地模型")
            }
            Rectangle().fill(UITheme.border).frame(height: 1)
            Text("开发者 API · 使用 API Key").font(.system(size: 11, weight: .medium)).foregroundStyle(UITheme.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 6) {
                ForEach(Provider.apiPresets.filter { $0 != .compatible }) { provider in
                    Button { add(provider) } label: {
                        HStack(spacing: 10) {
                            Text(provider.displayName).font(.system(size: 13))
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(UITheme.secondary)
                        }.padding(.horizontal, 12).frame(height: 42).contentShape(Rectangle())
                    }.buttonStyle(ModelOptionStyle())
                }
            }
            Button { add(.compatible) } label: {
                HStack {
                    Text("自定义兼容服务").font(.system(size: 12))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10))
                }.foregroundStyle(UITheme.secondary).padding(12).contentShape(Rectangle())
            }.buttonStyle(ModelOptionStyle())
        }
    }

    private func connectionOption(_ provider: Provider, title: String, subtitle: String) -> some View {
        Button { add(provider) } label: {
            HStack(spacing: 12) {
                providerIcon(provider)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(UITheme.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(UITheme.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(ModelOptionStyle())
    }

    private func providerIcon(_ provider: Provider) -> some View {
        Image(systemName: provider == .chatgpt ? "bubble.left.and.bubble.right" :
                provider == .doubao ? "terminal" : provider == .ollama ? "desktopcomputer" : "network")
            .font(.system(size: 15)).foregroundStyle(UITheme.secondary).frame(width: 22)
    }

    private var accountDialog: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(UITheme.success)
                Text(controller.email).font(.system(size: 13)).textSelection(.enabled)
            }
            Text("通过官方授权使用 ChatGPT 套餐。").font(.system(size: 12)).foregroundStyle(UITheme.secondary)
            Rectangle().fill(UITheme.border).frame(height: 1)
            Link(destination: URL(string: "https://chatgpt.com/settings/usage")!) {
                HStack {
                    Text("管理用量与授权")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }.font(.system(size: 13)).foregroundStyle(UITheme.text).padding(12)
            }.buttonStyle(ModelOptionStyle())
            HStack {
                Button("重新连接") { dialog = nil; signIn() }.buttonStyle(SettingsButtonStyle()).disabled(controller.busy)
                Spacer()
                Button("断开账号") { dialog = .disconnect }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(UITheme.secondary)
            }
        }
    }

    private func confirmationContent(_ value: ModelServiceDialog) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(value == .remove
                 ? "将移除“\(draft.serviceName)”。其他连接会保留，ChatGPT 的本次授权会同时撤销。"
                 : "将撤销本次登录授权，之后可以重新连接。")
                .font(.system(size: 13)).foregroundStyle(UITheme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { dialog = value == .remove ? .connections : .account }.buttonStyle(SettingsButtonStyle())
                Button(value == .remove ? "移除连接" : "断开账号") {
                    dialog = nil
                    if value == .remove { removeConnection() } else { disconnect() }
                }.buttonStyle(SettingsButtonStyle(primary: true))
            }
        }
    }

    private func add(_ provider: Provider) {
        apiKeys[draft.credentialAccount] = draft.apiKey
        draft.addConnection(provider)
        dialog = nil; controller.reset()
    }
    private func select(_ connection: ModelConnection) {
        guard connection.id != draft.activeConnectionID else { return }
        apiKeys[draft.credentialAccount] = draft.apiKey
        draft.rememberConnection()
        do {
            let key = try apiKeys[connection.credentialAccount] ?? store.apiKey(for: connection)
            draft.selectConnection(connection, key: key)
        } catch { controller.failed = true; controller.message = error.localizedDescription }
    }
    private func removeConnection() {
        guard let id = draft.activeConnectionID else { return }
        let wasChatGPT = draft.provider == .chatgpt
        controller.run {
            if wasChatGPT { try await ChatGPTAuth.shared.signOut(connectionID: id) }
            draft.connections.removeAll { $0.id == id }
            apiKeys.removeValue(forKey: "connection-\(id.uuidString)")
            if let next = draft.connections.first {
                let key = try apiKeys[next.credentialAccount] ?? store.apiKey(for: next)
                draft.selectConnection(next, key: key)
            } else { draft.activeConnectionID = nil; draft.addConnection(.volcengine) }
        }
    }
    private func disconnect() {
        guard let id = draft.activeConnectionID else { return }
        controller.run {
            try await ChatGPTAuth.shared.signOut(connectionID: id)
            controller.email = ""; controller.models = []; controller.message = "已断开 ChatGPT"
        }
    }
    private func loadIdentity() {
        guard draft.provider == .chatgpt, let id = draft.activeConnectionID else { return }
        controller.run { controller.email = try await ChatGPTAuth.shared.email(connectionID: id) ?? "" }
    }
    private func updateModels(_ values: [ServiceModel]) {
        controller.models = values
        controller.message = values.isEmpty ? "服务未返回可选模型，可手动填写" : ""
    }
    private func fetchModels() {
        let snapshot = draft.sanitized()
        controller.run {
            let values = try await ModelServiceClient.models(settings: snapshot)
            try Task.checkCancellation()
            updateModels(values)
        }
    }
    private func signIn() {
        guard let id = draft.activeConnectionID else { return }
        controller.run {
            controller.message = "请在浏览器中登录并完成授权…"
            controller.email = try await ChatGPTAuth.shared.signIn(connectionID: id)
            updateModels(try await ChatGPTAuth.shared.models(connectionID: id))
        }
    }
    private func checkDoubao() {
        guard let path = DoubaoCLI.resolve(draft.cliPath) else { controller.message = "请先安装官方豆包 CLI，或选择已安装的文件"; controller.failed = true; return }
        controller.run { controller.message = try await DoubaoCLI.status(path: path) }
    }
    private func loginDoubao() {
        guard let path = DoubaoCLI.resolve(draft.cliPath) else { controller.message = "请先安装官方豆包 CLI，或选择已安装的文件"; controller.failed = true; return }
        controller.run {
            controller.message = "正在等待豆包登录…"
            try await DoubaoCLI.login(path: path) { output in Task { @MainActor in controller.showQR(output) } }
            controller.message = try await DoubaoCLI.status(path: path)
        }
    }
    private func tryRewrite() {
        let snapshot = draft.sanitized(), source = testText
        controller.run {
            let started = Date()
            let result = try await RewriteService().rewrite(source, settings: snapshot)
            try Task.checkCancellation()
            guard draft.activeConnectionID == snapshot.activeConnectionID, testText == source else { throw CancellationError() }
            controller.result = result
            controller.message = String(format: "连接可用 · %.1f 秒", Date().timeIntervalSince(started))
        }
    }
}

private struct ModelPickerContent: View {
    @ObservedObject var controller: ModelConnectionController
    @Binding var selection: String
    let dismiss: () -> Void
    let refresh: () -> Void
    @State private var search = ""
    @State private var manual = false
    @State private var customModel = ""
    @FocusState private var searching: Bool

    private var filtered: [ServiceModel] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return controller.models.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                AppIcon(symbol: .search, size: .small).foregroundStyle(UITheme.secondary)
                TextField("搜索模型", text: $search).textFieldStyle(.plain).font(.system(size: 13))
                    .focused($searching).accessibilityLabel("搜索模型")
                    .onSubmit {
                        if let first = filtered.first { selection = first.id; dismiss() }
                    }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(UITheme.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 12).frame(height: 36).background(UITheme.field)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(UITheme.border, lineWidth: 1))
            ScrollView {
                LazyVStack(spacing: 4) {
                    if !controller.models.contains(where: { $0.id == selection }), !selection.isEmpty, search.isEmpty {
                        modelOption(ServiceModel(id: selection, name: selection), current: true)
                    }
                    ForEach(filtered) { model in modelOption(model) }
                    if filtered.isEmpty {
                        VStack(spacing: 6) {
                            Text(controller.busy ? "正在获取模型…" : controller.models.isEmpty ? "暂未获取到模型" : "没有匹配的模型")
                                .font(.system(size: 13))
                            if !controller.busy {
                                Text(controller.failed ? controller.message : "可以刷新列表，或手动输入模型名称。")
                                    .font(.system(size: 12)).foregroundStyle(controller.failed ? UITheme.error : UITheme.secondary)
                                    .multilineTextAlignment(.center).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 24).padding(.horizontal, 12)
                    }
                }
            }.frame(height: 240)
            Rectangle().fill(UITheme.border).frame(height: 1)
            HStack {
                Button { refresh() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text(controller.busy ? "正在刷新…" : "刷新列表")
                    }.font(.system(size: 12))
                }.buttonStyle(.plain).foregroundStyle(UITheme.secondary).disabled(controller.busy)
                Spacer()
                Button(manual ? "收起手动输入" : "手动输入模型") { manual.toggle(); customModel = selection }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(UITheme.secondary)
            }
            if manual {
                HStack(spacing: 8) {
                    TextField("填写完整模型名称", text: $customModel)
                        .textFieldStyle(.plain).font(.system(size: 13)).padding(.horizontal, 12).frame(height: 34)
                        .background(UITheme.field).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(UITheme.border, lineWidth: 1))
                        .onSubmit { useCustomModel() }.accessibilityLabel("手动模型名称")
                    Button("使用") { useCustomModel() }.buttonStyle(SettingsButtonStyle(primary: true))
                        .disabled(customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.onAppear { searching = true }
    }

    private func modelOption(_ model: ServiceModel, current: Bool = false) -> some View {
        Button { selection = model.id; dismiss() } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name).font(.system(size: 13, weight: selection == model.id ? .medium : .regular)).lineLimit(1)
                    if model.name != model.id || current {
                        Text(current ? "当前模型" : model.id).font(.system(size: 11)).foregroundStyle(UITheme.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if selection == model.id { AppIcon(symbol: .check, size: .small) }
            }.padding(12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(ModelOptionStyle(selected: selection == model.id))
        .accessibilityAddTraits(selection == model.id ? .isSelected : [])
    }

    private func useCustomModel() {
        let value = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        selection = value; dismiss()
    }
}

private struct ModelOptionStyle: ButtonStyle {
    var selected = false
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(UITheme.text)
            .background(selected || hovered || configuration.isPressed ? UITheme.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .onHover { hovered = $0 }
    }
}

private extension View {
    func modelInput() -> some View {
        textFieldStyle(.plain).font(.system(size: 13))
            .padding(.horizontal, 12).frame(width: 280, height: 34)
            .background(UITheme.field).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(UITheme.border, lineWidth: 1))
    }
}
