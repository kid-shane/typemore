import Foundation

enum ModelServiceClient {
    static func baseURL(_ endpoint: String) -> String {
        var value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        for suffix in ["/chat/completions", "/responses", "/messages"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
            break
        }
        return value
    }
    static func url(_ endpoint: String) throws -> URL {
        guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
              url.user == nil, url.password == nil else { throw RewriteError.invalidEndpoint }
        return url
    }
    static func authorize(_ request: inout URLRequest, settings: AppSettings) {
        if settings.provider == .anthropic {
            request.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if !settings.workspaceID.isEmpty { request.setValue(settings.workspaceID, forHTTPHeaderField: "anthropic-workspace-id") }
        } else if !settings.apiKey.isEmpty { request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization") }
    }
    static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw TypemoreError.invalidModelResponse }
        guard (200..<300).contains(http.statusCode) else {
            let text: String
            switch http.statusCode {
            case 401, 403: text = "凭据无效或没有权限，请检查账号与 API Key"
            case 404: text = "服务地址或模型未找到，请检查配置"
            case 429: text = "额度不足或请求过于频繁，请查看服务商的用量设置"
            default: text = "模型服务暂时不可用（\(http.statusCode)），请稍后重试"
            }
            throw ModelServiceError.message(text)
        }
    }
    static func models(settings: AppSettings) async throws -> [ServiceModel] {
        if settings.provider == .chatgpt {
            guard let id = settings.activeConnectionID else { throw ModelServiceError.message("请先登录 ChatGPT") }
            return try await ChatGPTAuth.shared.models(connectionID: id)
        }
        if settings.provider == .doubao { return [] }
        if settings.provider.requiresAPIKey && settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw RewriteError.missingAPIKey }
        var request = URLRequest(url: try url(baseURL(settings.endpoint) + "/models"))
        request.timeoutInterval = 20
        authorize(&request, settings: settings)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = json["data"] as? [[String: Any]] else {
            throw ModelServiceError.message("服务未提供模型列表，请手动填写模型名称")
        }
        let excluded = ["embedding", "whisper", "tts", "dall-e", "moderation", "audio", "realtime", "image", "video"]
        var seen = Set<String>()
        return rows.compactMap { item -> ServiceModel? in
            guard let id = item["id"] as? String, !excluded.contains(where: { id.lowercased().contains($0) }), seen.insert(id).inserted else { return nil }
            return ServiceModel(id: id, name: item["display_name"] as? String ?? item["name"] as? String ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
