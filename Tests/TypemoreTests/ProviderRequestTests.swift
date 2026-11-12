import Foundation
import XCTest
@testable import Typemore

private final class ProviderStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "typemore.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, data.isEmpty {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

final class ProviderRequestTests: XCTestCase {
    override func setUp() { super.setUp(); URLProtocol.registerClass(ProviderStub.self) }
    override func tearDown() { ProviderStub.handler = nil; URLProtocol.unregisterClass(ProviderStub.self); super.tearDown() }

    func testProviderThinkingFieldsAndLocalNoKey() async throws {
        let providers: [Provider] = [.volcengine, .deepseek, .bailian, .kimi, .gemini, .openrouter, .compatible, .ollama]
        for provider in providers {
            var settings = AppSettings.defaults
            settings.provider = provider; settings.endpoint = "https://typemore.test/v1"; settings.model = "test-model"
            settings.apiKey = provider == .ollama ? "" : "fake-test-key"
            settings.thinkingEnabled = false
            var requests = 0
            ProviderStub.handler = { request in
                requests += 1
                XCTAssertEqual(request.url?.path, "/v1/chat/completions")
                let body = try ProviderStub.body(request)
                XCTAssertNil(body["temperature"])
                if [.volcengine, .deepseek, .kimi].contains(provider) {
                    XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
                } else { XCTAssertNil(body["thinking"]) }
                if provider == .bailian { XCTAssertEqual(body["enable_thinking"] as? Bool, false) }
                else { XCTAssertNil(body["enable_thinking"]) }
                return (200, Data(#"{"choices":[{"message":{"content":"我们可以先尝试，再决定是否继续。"},"finish_reason":"stop"}]}"#.utf8))
            }
            let result = try await RewriteService().rewrite("我们可以先试试看，再决定要不要继续。", settings: settings)
            XCTAssertEqual(result, "我们可以先尝试，再决定是否继续。")
            XCTAssertEqual(requests, 1)
        }
    }
    func testOpenAIResponsesAndAnthropicNative() async throws {
        var settings = AppSettings.defaults
        settings.provider = .openai; settings.endpoint = "https://typemore.test/v1/responses"; settings.model = "test-model"; settings.apiKey = "fake-test-key"
        ProviderStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/responses")
            let body = try ProviderStub.body(request)
            XCTAssertEqual(body["store"] as? Bool, false)
            XCTAssertNil(body["temperature"])
            XCTAssertNotNil(body["max_output_tokens"])
            return (200, Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"我们可以先尝试，再决定是否继续。"}]}]}"#.utf8))
        }
        _ = try await RewriteService().rewrite("我们可以先试试看，再决定要不要继续。", settings: settings)
        settings.provider = .anthropic; settings.endpoint = "https://typemore.test/v1"; settings.workspaceID = "test-workspace"
        ProviderStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fake-test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-workspace-id"), "test-workspace")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            let body = try ProviderStub.body(request)
            XCTAssertNotNil(body["system"])
            return (200, Data(#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"Do not return this"},{"type":"text","text":"我们可以先尝试，再决定是否继续。"}]}"#.utf8))
        }
        let result = try await RewriteService().rewrite("我们可以先试试看，再决定要不要继续。", settings: settings)
        XCTAssertEqual(result, "我们可以先尝试，再决定是否继续。")
    }
    func testCatalogFiltersNonTextModelsAndKeepsDisplayNames() async throws {
        var settings = AppSettings.defaults
        settings.endpoint = "https://typemore.test/v1/chat/completions"; settings.apiKey = "fake-test-key"
        ProviderStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            return (200, Data(#"{"data":[{"id":"text-model","display_name":"可用文本模型"},{"id":"text-embedding-3-small"},{"id":"text-model"}]}"#.utf8))
        }
        let models = try await ModelServiceClient.models(settings: settings)
        XCTAssertEqual(models, [ServiceModel(id: "text-model", name: "可用文本模型")])
    }
}

extension ProviderRequestTests {
    func testStreamingCompatibilityAPICollectsOnlyFinalText() async throws {
        var settings = AppSettings.defaults
        settings.provider = .bailian; settings.endpoint = "https://typemore.test/v1"; settings.model = "test-model"; settings.apiKey = "fake-test-key"
        ProviderStub.handler = { request in
            let body = try ProviderStub.body(request)
            XCTAssertEqual(body["stream"] as? Bool, true)
            return (200, Data("""
            data: {"choices":[{"delta":{"reasoning_content":"隐藏思考"},"finish_reason":null}]}

            data: {"choices":[{"delta":{"content":"我们可以先尝试，"},"finish_reason":null}]}

            data: {"choices":[{"delta":{"content":"再决定是否继续。"},"finish_reason":null}]}

            data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

            data: [DONE]

            """.utf8))
        }
        let result = try await RewriteService().rewrite("我们可以先试试看，再决定要不要继续。", settings: settings)
        XCTAssertEqual(result, "我们可以先尝试，再决定是否继续。")
    }
}
