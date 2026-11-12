import Foundation
import XCTest
@testable import Typemore

final class ModelConnectionTests: XCTestCase {
    @MainActor func testNewAPIConnectionStaysUnselectedUntilUserChoosesModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        var secrets = [String: String]()
        let store = SettingsStore(fileURL: file, secretReader: { secrets[$0] }, secretWriter: { secrets[$0] = $1 })
        var draft = store.settings
        draft.addConnection(.openai)
        try store.save(draft)
        let reloaded = SettingsStore(fileURL: file, secretReader: { secrets[$0] }, secretWriter: { secrets[$0] = $1 })
        XCTAssertTrue(reloaded.settings.model.isEmpty)
        XCTAssertTrue(try XCTUnwrap(reloaded.settings.connections.last).model.isEmpty)
        draft = reloaded.settings
        draft.model = "user-selected-model"
        try reloaded.save(draft)
        let selected = SettingsStore(fileURL: file, secretReader: { secrets[$0] }, secretWriter: { secrets[$0] = $1 })
        XCTAssertEqual(selected.settings.model, "user-selected-model")
    }

    func testMissingModelStopsRewriteBeforeRequest() async throws {
        var settings = AppSettings.defaults
        settings.addConnection(.openai)
        settings.apiKey = "test-key"
        do {
            _ = try await RewriteService().rewrite("这句话可以改一下。", settings: settings)
            XCTFail("Expected a missing model error")
        } catch RewriteError.missingModel { }
    }

    @MainActor func testMigrationAndConnectionRoundTripKeepWritingPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("settings.json")
        let legacy = Data(#"{"provider":"compatible","endpoint":"https://first.example/v1","model":"first-model","customStyle":"保留这份文风","rewriteTrigger":{"kind":"chord","chord":{"modifiers":["control","option"],"keyCode":15,"keyLabel":"R"}}}"#.utf8)
        try legacy.write(to: file)
        var secrets = ["api-key-compatible": "first-test-secret"]
        let store = SettingsStore(fileURL: file, secretReader: { secrets[$0] }, secretWriter: { secrets[$0] = $1 })
        var draft = store.settings
        let first = try XCTUnwrap(draft.connections.first)
        XCTAssertEqual(draft.apiKey, "first-test-secret")
        draft.addConnection(.compatible)
        draft.endpoint = "https://second.example/v1"
        draft.model = "second-model"
        draft.apiKey = "second-test-secret"
        try store.save(draft, apiKeys: [first.credentialAccount: "first-test-secret"])
        let reloaded = SettingsStore(fileURL: file, secretReader: { secrets[$0] }, secretWriter: { secrets[$0] = $1 })
        XCTAssertEqual(reloaded.settings.connections.count, 2)
        XCTAssertEqual(reloaded.settings.model, "second-model")
        XCTAssertEqual(reloaded.settings.apiKey, "second-test-secret")
        XCTAssertEqual(try reloaded.apiKey(for: first), "first-test-secret")
        XCTAssertEqual(reloaded.settings.customStyle, "保留这份文风")
        XCTAssertEqual(reloaded.settings.rewriteTrigger.displayText, "⌃⌥R")
        let saved = try String(contentsOf: file)
        XCTAssertFalse(saved.contains("first-test-secret"))
        XCTAssertFalse(saved.contains("second-test-secret"))
        var selected = reloaded.settings
        selected.selectConnection(first, key: try reloaded.apiKey(for: first))
        XCTAssertEqual(selected.endpoint, "https://first.example/v1")
        XCTAssertEqual(selected.model, "first-model")
    }

    @MainActor func testKeychainFailurePreservesSavedConfigurationAndReturnsError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: file, secretReader: { _ in nil }, secretWriter: { _, _ in throw ModelServiceError.message("钥匙串拒绝写入") })
        let original = store.settings
        var changed = original
        changed.model = "changed-model"
        changed.apiKey = "a-test-key"
        XCTAssertThrowsError(try store.save(changed))
        XCTAssertEqual(store.settings, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testResponsesStreamRequiresFinalCompletionAndRejectsFailureAfterText() throws {
        var success = ResponsesStream()
        try success.consume(#"data: {"type":"response.output_text.delta","delta":"改写正文"}"#)
        XCTAssertThrowsError(try success.result())
        try success.consume(#"data: {"type":"response.completed"}"#)
        XCTAssertEqual(try success.result(), "改写正文")
        var failed = ResponsesStream()
        try failed.consume(#"data: {"type":"response.output_text.delta","delta":"只有部分正文"}"#)
        XCTAssertThrowsError(try failed.consume(#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#))
        XCTAssertThrowsError(try failed.result())
    }

    func testLocalCommandCancellationStopsOwnedProcessPromptly() async throws {
        let started = Date()
        let task = Task { try await LocalCommand.run(path: "/bin/sleep", arguments: ["20"], timeout: 25) }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testEndpointsAndLocalAuthentication() throws {
        XCTAssertEqual(ModelServiceClient.baseURL("https://api.example/v1/responses/"), "https://api.example/v1")
        XCTAssertEqual(ModelServiceClient.baseURL("https://api.example/v1/chat/completions"), "https://api.example/v1")
        XCTAssertNoThrow(try ModelServiceClient.url("http://localhost:11434/v1"))
        XCTAssertThrowsError(try ModelServiceClient.url("http://remote.example/v1"))
        XCTAssertFalse(Provider.ollama.requiresAPIKey)
    }
}

final class OAuthCallbackTests: XCTestCase {
    func testLoopbackRejectsWrongStateAndAcceptsExpectedCallback() async throws {
        let listener = try OAuthLoopback(state: "expected-test-state")
        defer { listener.stop() }
        let redirect = try await listener.redirectURI()
        let (_, rejected) = try await URLSession.shared.data(from: URL(string: redirect + "?state=wrong&code=forged")!)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
        let (_, accepted) = try await URLSession.shared.data(from: URL(string: redirect + "?state=expected-test-state&code=valid-test-code&client_id=test-client")!)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        let result = try await listener.result()
        XCTAssertEqual(result["code"], "valid-test-code")
        XCTAssertEqual(result["client_id"], "test-client")
    }

    func testStreamingChatNeverAcceptsTruncatedResult() throws {
        var stream = ChatCompletionStream()
        try stream.consume(#"data: {"choices":[{"delta":{"content":"部分正文"},"finish_reason":null}]}"#)
        XCTAssertThrowsError(try stream.result())
        XCTAssertThrowsError(try stream.consume(#"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#))
    }
}
