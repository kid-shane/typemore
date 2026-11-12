import AppKit
import CryptoKit
import Foundation
import Network
import Security

private struct ChatGPTSession: Codable {
    var clientID: String
    var subject: String
    var email: String
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var scopes: String
    var expiresAt: Date
}

final class OAuthLoopback: @unchecked Sendable {
    private let listener: NWListener
    private let state: String
    private let lock = NSLock()
    private var callback: [String: String]?
    private var failure: Error?
    private var ready = false
    init(state: String) throws {
        self.state = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] status in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            switch status {
            case .ready: self.ready = true
            case .failed(let error): self.failure = error
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.receive(connection, buffer: Data()) }
        listener.start(queue: .global(qos: .userInitiated))
    }
    func stop() { listener.cancel() }
    private func snapshot() -> (Bool, [String: String]?, Error?) {
        lock.lock(); defer { lock.unlock() }; return (ready, callback, failure)
    }
    func redirectURI() async throws -> String {
        for _ in 0..<100 {
            try Task.checkCancellation()
            let value = snapshot()
            if let error = value.2 { throw error }
            if value.0, let port = listener.port { return "http://127.0.0.1:\(port.rawValue)/auth/callback" }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw ModelServiceError.message("本机登录回调未能启动，请重试")
    }
    func result() async throws -> [String: String] {
        for _ in 0..<6000 {
            try Task.checkCancellation()
            let value = snapshot()
            if let error = value.2 { throw error }
            if let callback = value.1 { return callback }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ModelServiceError.message("登录等待超时，请重新连接 ChatGPT")
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        if buffer.isEmpty { connection.start(queue: .global(qos: .userInitiated)) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var next = buffer; if let data { next.append(data) }
            guard next.count <= 16384 else { connection.cancel(); return }
            let request = String(decoding: next, as: UTF8.self)
            if !request.contains("\r\n\r\n"), !complete, error == nil { self.receive(connection, buffer: next); return }
            let line = request.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            var valid = false
            if parts.count >= 2, parts[0] == "GET",
               let url = URLComponents(string: "http://127.0.0.1" + parts[1]), url.path == "/auth/callback" {
                let pairs = url.queryItems ?? []
                let values = Dictionary(pairs.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
                if values["state"] == self.state {
                    self.lock.lock(); if self.callback == nil { self.callback = values }; self.lock.unlock()
                    valid = true
                }
            }
            let html = valid ? "授权已返回，请回到 Typemore 完成连接。" : "此登录回调无效，请回到 Typemore 重试。"
            let body = "<!doctype html><meta charset=utf-8><title>Typemore</title><p>\(html)</p>"
            let response = "HTTP/1.1 \(valid ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

actor ChatGPTAuth {
    static let shared = ChatGPTAuth()
    private let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private var refreshTasks: [UUID: Task<ChatGPTSession, Error>] = [:]
    private func account(_ id: UUID) -> String { "chatgpt-session-\(id.uuidString)" }
    private func stored(_ id: UUID) throws -> ChatGPTSession? {
        guard let value = try KeychainStore.readSecret(account(id)) else { return nil }
        return try JSONDecoder().decode(ChatGPTSession.self, from: Data(value.utf8))
    }
    func email(connectionID: UUID) throws -> String? { try stored(connectionID)?.email }
    private func save(_ session: ChatGPTSession, _ id: UUID) throws {
        let value = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        try KeychainStore.writeSecret(account(id), value)
    }
    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Data(bytes).base64URL
    }
    func signIn(connectionID: UUID) async throws -> String {
        let previous = try stored(connectionID)
        let registrationKey = "chatgpt-client-\(connectionID.uuidString)"
        let clientID = previous?.clientID ?? UserDefaults.standard.string(forKey: registrationKey) ?? "dynamic_agent_client"
        let hostKey = "chatgpt-agent-host-id"
        let hostID = UserDefaults.standard.string(forKey: hostKey) ?? "urn:uuid:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(hostID, forKey: hostKey)
        let state = Self.random(), nonce = Self.random(), verifier = Self.random()
        let callback = try OAuthLoopback(state: state)
        defer { callback.stop() }
        let redirect = try await callback.redirectURI()
        var parameters = ["client_id": clientID, "ext_agent_host_id": hostID, "response_type": "code",
                          "redirect_uri": redirect, "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                          "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce,
                          "code_challenge_method": "S256", "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL]
        if clientID == "dynamic_agent_client" { parameters["agent_name_hint"] = "Typemore" }
        else if let previous { parameters["id_token_hint"] = previous.idToken }
        var url = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        url.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let target = url.url, await MainActor.run(body: { NSWorkspace.shared.open(target) }) else {
            throw ModelServiceError.message("浏览器未能打开，请重试")
        }
        let values = try await callback.result()
        if values["error"] != nil { throw ModelServiceError.message("ChatGPT 授权未完成，请重新连接") }
        let issued = values["client_id"] ?? clientID
        guard issued != "dynamic_agent_client", issued == clientID || clientID == "dynamic_agent_client",
              let code = values["code"], !code.isEmpty else { throw ModelServiceError.message("ChatGPT 注册未完成，请重试") }
        UserDefaults.standard.set(issued, forKey: registrationKey)
        let json = try await tokenRequest(["grant_type": "authorization_code", "client_id": issued,
                                           "code": code, "code_verifier": verifier, "redirect_uri": redirect,
                                           "resource": "https://api.openai.com/v1"])
        guard let token = json["id_token"] as? String else { throw ModelServiceError.message("登录响应缺少账号验证信息") }
        let identity = try await Self.validateIDToken(token, clientID: issued, nonce: nonce)
        if let previous, previous.subject != identity.subject { throw ModelServiceError.message("登录账号发生变化，请新建 ChatGPT 连接") }
        let scopes = json["scope"] as? String ?? ""
        guard scopes.split(separator: " ").contains("chatgpt.tokens.use.direct") else {
            throw ModelServiceError.message("账号尚未授权 Typemore 使用 ChatGPT 套餐，请重新登录并允许使用套餐")
        }
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw ModelServiceError.message("ChatGPT 登录凭据不完整，请重试")
        }
        try Task.checkCancellation()
        let session = ChatGPTSession(clientID: issued, subject: identity.subject, email: identity.email,
                                     accessToken: access, refreshToken: refresh, idToken: token, scopes: scopes,
                                     expiresAt: Date().addingTimeInterval(json["expires_in"] as? Double ?? 3600))
        try save(session, connectionID)
        return identity.email
    }
    private func tokenRequest(_ parameters: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(parameters)
        let (data, response) = try await URLSession.shared.data(for: request)
        try ModelServiceClient.validate(response, data: data)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    private func session(_ id: UUID) async throws -> ChatGPTSession {
        guard let current = try stored(id) else { throw ModelServiceError.message("请先连接 ChatGPT 账号") }
        if current.expiresAt.timeIntervalSinceNow > 90 { return current }
        if let pending = refreshTasks[id] { return try await pending.value }
        let task = Task { () throws -> ChatGPTSession in
            let json = try await self.tokenRequest(["grant_type": "refresh_token", "client_id": current.clientID,
                                                    "refresh_token": current.refreshToken, "resource": "https://api.openai.com/v1"])
            guard let access = json["access_token"] as? String else { throw ModelServiceError.message("ChatGPT 连接已过期，请重新登录") }
            var next = current
            next.accessToken = access
            next.refreshToken = json["refresh_token"] as? String ?? current.refreshToken
            next.scopes = json["scope"] as? String ?? current.scopes
            next.expiresAt = Date().addingTimeInterval(json["expires_in"] as? Double ?? 3600)
            if let token = json["id_token"] as? String {
                let identity = try await Self.validateIDToken(token, clientID: current.clientID, nonce: nil)
                guard identity.subject == current.subject else { throw ModelServiceError.message("ChatGPT 账号验证失败，请重新登录") }
                next.idToken = token; next.email = identity.email
            }
            guard next.scopes.split(separator: " ").contains("chatgpt.tokens.use.direct") else { throw ModelServiceError.message("ChatGPT 套餐授权已失效，请重新登录") }
            return next
        }
        refreshTasks[id] = task
        defer { refreshTasks[id] = nil }
        let next = try await task.value
        try Task.checkCancellation()
        guard let latest = try stored(id) else { throw ModelServiceError.message("ChatGPT 已断开连接") }
        if latest.refreshToken != current.refreshToken { return latest }
        try save(next, id)
        return next
    }
    func signOut(connectionID: UUID) async throws {
        refreshTasks[connectionID]?.cancel()
        guard let session = try stored(connectionID) else { return }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
        let discovery = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let value = discovery["revocation_endpoint"] as? String,
              let url = URL(string: value), url.scheme == "https", url.host == "auth.openai.com" else { throw ModelServiceError.message("账号断开失败，请稍后重试，或前往 ChatGPT 设置管理授权") }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(["token": session.refreshToken, "token_type_hint": "refresh_token", "client_id": session.clientID])
        let (result, response) = try await URLSession.shared.data(for: request)
        try ModelServiceClient.validate(response, data: result)
        try KeychainStore.writeSecret(account(connectionID), "")
    }
    func models(connectionID: UUID) async throws -> [ServiceModel] {
        let session = try await session(connectionID)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!); request.timeoutInterval = 25
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try ModelServiceClient.validate(response, data: data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return (json["models"] as? [[String: Any]] ?? []).compactMap { item in
            guard item["visibility"] as? String == "list", let id = item["slug"] as? String else { return nil }
            return ServiceModel(id: id, name: item["display_name"] as? String ?? id)
        }
    }
    func rewrite(system: String, message: String, model: String, connectionID: UUID) async throws -> String {
        let session = try await session(connectionID)
        guard !model.isEmpty else { throw ModelServiceError.message("请在模型服务中选择 ChatGPT 模型") }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "instructions": system,
                "input": [["role": "user", "content": message]], "store": false, "stream": true])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try ModelServiceClient.validate(response, data: Data())
        var parser = ResponsesStream()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try parser.consume(line)
        }
        return try parser.result()
    }
    private static func form(_ parameters: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(parameters.map { ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&").utf8)
    }
    private static func validateIDToken(_ token: String, clientID: String, nonce: String?) async throws -> (subject: String, email: String) {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3, let headerData = Data(base64URL: parts[0]), let claimsData = Data(base64URL: parts[1]),
              let signature = Data(base64URL: parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              let kid = header["kid"] as? String, let algorithm = header["alg"] as? String else { throw ModelServiceError.message("ChatGPT 账号签名验证失败") }
        let (discoveryData, _) = try await URLSession.shared.data(from: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
        let discovery = try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any] ?? [:]
        guard let raw = discovery["jwks_uri"] as? String, let url = URL(string: raw), url.scheme == "https", url.host == "auth.openai.com" else { throw ModelServiceError.message("ChatGPT 验证服务不可用") }
        let (keysData, _) = try await URLSession.shared.data(from: url)
        let keys = (try JSONSerialization.jsonObject(with: keysData) as? [String: Any])?["keys"] as? [[String: Any]] ?? []
        guard let jwk = keys.first(where: { $0["kid"] as? String == kid }) else { throw ModelServiceError.message("ChatGPT 验证密钥未找到，请重试") }
        let signed = Data((parts[0] + "." + parts[1]).utf8)
        var valid = false
        if algorithm == "RS256", let n = jwk["n"] as? String, let e = jwk["e"] as? String,
           let modulus = Data(base64URL: n), let exponent = Data(base64URL: e) {
            func length(_ count: Int) -> Data {
                if count < 128 { return Data([UInt8(count)]) }
                return count < 256 ? Data([0x81, UInt8(count)]) : Data([0x82, UInt8(count >> 8), UInt8(count & 255)])
            }
            func integer(_ value: Data) -> Data {
                let bytes = value.first.map { $0 >= 128 } == true ? Data([0]) + value : value
                return Data([2]) + length(bytes.count) + bytes
            }
            let body = integer(modulus) + integer(exponent)
            let encoded = Data([0x30]) + length(body.count) + body
            let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits as String: modulus.count * 8]
            if let key = SecKeyCreateWithData(encoded as CFData, attrs as CFDictionary, nil) {
                valid = SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil)
            }
        } else if algorithm == "ES256", let x = jwk["x"] as? String, let y = jwk["y"] as? String,
                  let dx = Data(base64URL: x), let dy = Data(base64URL: y),
                  let key = try? P256.Signing.PublicKey(x963Representation: Data([4]) + dx + dy),
                  let value = try? P256.Signing.ECDSASignature(rawRepresentation: signature) {
            valid = key.isValidSignature(value, for: signed)
        }
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard valid, claims["iss"] as? String == "https://auth.openai.com", audience.contains(clientID),
              (claims["exp"] as? Double ?? 0) > Date().timeIntervalSince1970,
              nonce == nil || claims["nonce"] as? String == nonce,
              let subject = claims["sub"] as? String, !subject.isEmpty else { throw ModelServiceError.message("ChatGPT 账号验证未通过，请重新登录") }
        return (subject, claims["email"] as? String ?? "已连接的 ChatGPT 账号")
    }
}

struct ResponsesStream {
    private var text = ""
    private var completed = false
    mutating func consume(_ line: String) throws {
        guard line.hasPrefix("data:"), let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch event["type"] as? String {
        case "response.output_text.delta": text += event["delta"] as? String ?? ""
        case "response.completed": completed = true
        case "response.failed", "response.incomplete", "error":
            throw ModelServiceError.message("ChatGPT 未能完成改写，请检查套餐用量或重新连接账号；原文已保留")
        default: break
        }
    }
    func result() throws -> String {
        guard completed, !text.isEmpty else { throw RewriteError.incompleteOutput }
        return text
    }
}

private extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}
