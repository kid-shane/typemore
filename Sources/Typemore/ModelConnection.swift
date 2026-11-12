import Foundation

enum Provider: String, CaseIterable, Codable, Identifiable {
    case volcengine, deepseek, bailian, kimi, openai, gemini, anthropic, openrouter, compatible, ollama
    case chatgpt, doubao, demo
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .volcengine: return "火山方舟"
        case .deepseek: return "DeepSeek"
        case .bailian: return "阿里云百炼"
        case .kimi: return "Kimi"
        case .openai: return "OpenAI API"
        case .gemini: return "Google Gemini"
        case .anthropic: return "Claude"
        case .openrouter: return "OpenRouter"
        case .compatible: return "自定义兼容服务"
        case .ollama: return "Ollama 本地模型"
        case .chatgpt: return "ChatGPT"
        case .doubao: return "豆包 CLI"
        case .demo: return "本地演示"
        }
    }
    var defaultEndpoint: String {
        switch self {
        case .volcengine: return "https://ark.cn-beijing.volces.com/api/v3"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .bailian: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .openai, .chatgpt: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .ollama: return "http://localhost:11434/v1"
        default: return ""
        }
    }
    var defaultModel: String {
        switch self {
        default: return ""
        }
    }
    var requiresAPIKey: Bool {
        switch self {
        case .demo, .ollama, .chatgpt, .doubao: return false
        default: return true
        }
    }
    var supportsThinkingToggle: Bool { [.volcengine, .deepseek, .bailian, .kimi].contains(self) }
    var keyURL: URL? {
        let value: String
        switch self {
        case .volcengine: value = "https://ark.volcengine.com/apiKey"
        case .deepseek: value = "https://platform.deepseek.com/api_keys"
        case .bailian: value = "https://bailian.console.aliyun.com/"
        case .kimi: value = "https://platform.kimi.com/console/api-keys"
        case .openai: value = "https://platform.openai.com/api-keys"
        case .gemini: value = "https://aistudio.google.com/apikey"
        case .anthropic: value = "https://platform.claude.com/settings/keys"
        case .openrouter: value = "https://openrouter.ai/settings/keys"
        default: return nil
        }
        return URL(string: value)
    }
    static let apiPresets: [Provider] = [.volcengine, .deepseek, .bailian, .kimi, .openai, .gemini, .anthropic, .openrouter, .compatible]
}

struct ModelConnection: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var provider: Provider
    var endpoint: String
    var model: String
    var thinkingEnabled: Bool
    var volcengineEndpointKind: VolcengineEndpointKind
    var cliPath: String
    var workspaceID: String?

    init(settings: AppSettings, id: UUID) {
        self.id = id
        name = settings.serviceName
        provider = settings.provider
        endpoint = settings.endpoint
        model = settings.model
        thinkingEnabled = settings.thinkingEnabled
        volcengineEndpointKind = settings.volcengineEndpointKind
        cliPath = settings.cliPath
        workspaceID = settings.workspaceID.isEmpty ? nil : settings.workspaceID
    }
    var credentialAccount: String { "connection-\(id.uuidString)" }
}

extension AppSettings {
    var credentialAccount: String {
        activeConnectionID.map { "connection-\($0.uuidString)" } ?? "api-key-\(provider.rawValue)"
    }
    mutating func rememberConnection() {
        guard let id = activeConnectionID else { return }
        let connection = ModelConnection(settings: self, id: id)
        if let index = connections.firstIndex(where: { $0.id == id }) { connections[index] = connection }
        else { connections.append(connection) }
    }
    mutating func ensureConnection() {
        if activeConnectionID == nil { activeConnectionID = UUID(); rememberConnection() }
    }
    mutating func selectConnection(_ connection: ModelConnection, key: String) {
        activeConnectionID = connection.id
        serviceName = connection.name
        provider = connection.provider
        endpoint = connection.endpoint
        model = connection.model
        thinkingEnabled = connection.thinkingEnabled
        volcengineEndpointKind = connection.volcengineEndpointKind
        cliPath = connection.cliPath
        workspaceID = connection.workspaceID ?? ""
        apiKey = key
    }
    mutating func addConnection(_ provider: Provider) {
        rememberConnection()
        activeConnectionID = UUID()
        self.provider = provider
        let count = connections.filter { $0.provider == provider }.count
        serviceName = provider.displayName + (count > 0 ? " \(count + 1)" : "")
        endpoint = provider.defaultEndpoint
        model = provider.defaultModel
        apiKey = ""
        thinkingEnabled = false
        volcengineEndpointKind = .api
        cliPath = ""
        workspaceID = ""
        rememberConnection()
    }
}

struct ServiceModel: Identifiable, Equatable {
    let id: String
    let name: String
}

enum ModelServiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
