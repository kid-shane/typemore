import Security
import XCTest
@testable import Typemore

final class KeychainRecoveryTests: XCTestCase {
    func testRecoveryAdviceOffersInAppVerification() {
        let authentication = KeychainStoreError(operation: .read, status: errSecAuthFailed)
        XCTAssertTrue(authentication.localizedDescription.contains("暂时无法访问"))
        XCTAssertTrue(authentication.recoverySuggestion?.contains("恢复连接") == true)
        XCTAssertFalse(authentication.recoverySuggestion?.contains("重新启动") == true)
        let unexpected = KeychainStoreError(operation: .save, status: errSecNotAvailable)
        XCTAssertTrue(unexpected.localizedDescription.contains("保存失败"))
        XCTAssertNil(unexpected.recoverySuggestion)
    }

    func testRecoveryUnlocksImmediatelyAfterLocking() throws {
        var calls: [String] = []
        try KeychainStore.reauthenticate(lock: {
            calls.append("lock")
            return errSecSuccess
        }, unlock: {
            calls.append("unlock")
            return errSecSuccess
        })
        XCTAssertEqual(calls, ["lock", "unlock"])
    }

    func testLockFailureStopsRecoveryAndUnlockCancellationIsReported() {
        var unlocked = false
        XCTAssertThrowsError(try KeychainStore.reauthenticate(lock: { errSecAuthFailed }, unlock: {
            unlocked = true
            return errSecSuccess
        })) { XCTAssertEqual(($0 as? KeychainStoreError)?.status, errSecAuthFailed) }
        XCTAssertFalse(unlocked)
        XCTAssertThrowsError(try KeychainStore.reauthenticate(lock: { errSecSuccess }, unlock: { errSecUserCanceled })) {
            XCTAssertEqual(($0 as? KeychainStoreError)?.status, errSecUserCanceled)
        }
    }

    @MainActor func testRecoveryReplaysTheFailedOperationAfterSystemVerification() async throws {
        let controller = ModelConnectionController()
        var available = false
        var attempts = 0
        controller.run {
            attempts += 1
            guard available else { throw KeychainStoreError(operation: .read, status: errSecAuthFailed) }
            controller.email = "test@example.com"
        }
        try await finish(controller)
        XCTAssertTrue(controller.failed)
        XCTAssertTrue(controller.hasCredentialRetry)
        controller.recoverCredentials(using: { available = true })
        try await finish(controller)
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(controller.failed)
        XCTAssertNil(controller.keychainError)
        XCTAssertFalse(controller.hasCredentialRetry)
        XCTAssertFalse(controller.recoveringCredentials)
        XCTAssertEqual(controller.email, "test@example.com")
    }

    @MainActor func testFailedVerificationRetainsOriginalOperationForNextRecovery() async throws {
        let controller = ModelConnectionController()
        var available = false
        var attempts = 0
        var verifications = 0
        controller.run {
            attempts += 1
            guard available else { throw KeychainStoreError(operation: .read, status: errSecAuthFailed) }
        }
        try await finish(controller)
        controller.recoverCredentials(using: {
            verifications += 1
            throw KeychainStoreError(operation: .authenticate, status: errSecUserCanceled)
        })
        try await finish(controller)
        XCTAssertTrue(controller.failed)
        XCTAssertEqual(attempts, 1)
        controller.recoverCredentials(using: { verifications += 1; available = true })
        try await finish(controller)
        XCTAssertEqual(verifications, 2)
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(controller.failed)
    }

    @MainActor func testSuccessfulSystemCallStillRequiresTheCredentialReadToSucceed() async throws {
        let controller = ModelConnectionController()
        var attempts = 0
        controller.run {
            attempts += 1
            throw KeychainStoreError(operation: .read, status: errSecAuthFailed)
        }
        try await finish(controller)
        controller.recoverCredentials(using: {})
        try await finish(controller)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(controller.failed)
        XCTAssertNotNil(controller.keychainError)
    }

    @MainActor func testAPIKeyRecoveryPreservesLegacyCredentialLookupAndSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("settings.json")
        let original = Data(#"{"provider":"compatible","model":"saved-model","customStyle":"保留风格"}"#.utf8)
        try original.write(to: file)
        var available = false
        var writes = 0
        let store = SettingsStore(fileURL: file, secretReader: { account in
            guard available else { throw KeychainStoreError(operation: .read, status: errSecAuthFailed) }
            return account == "api-key-compatible" ? "saved-test-key" : nil
        }, secretWriter: { _, _ in writes += 1 })
        XCTAssertNotNil(store.credentialFailure)
        available = true
        let connection = try XCTUnwrap(store.settings.connections.first)
        XCTAssertEqual(try store.reloadAPIKey(for: connection), "saved-test-key")
        XCTAssertNil(store.credentialFailure)
        XCTAssertTrue(store.credentialError.isEmpty)
        XCTAssertEqual(store.settings.model, "saved-model")
        XCTAssertEqual(store.settings.customStyle, "保留风格")
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(writes, 0)
    }

    @MainActor func testSwitchingConnectionClearsThePendingRecovery() async throws {
        let controller = ModelConnectionController()
        controller.run { throw KeychainStoreError(operation: .read, status: errSecUserCanceled) }
        try await finish(controller)
        controller.reset()
        XCTAssertNil(controller.keychainError)
        XCTAssertFalse(controller.hasCredentialRetry)
        XCTAssertTrue(controller.message.isEmpty)
        XCTAssertFalse(controller.failed)
    }

    @MainActor func testLeavingDuringVerificationWaitsForCompletionWithoutReplayingTheOperation() async throws {
        let controller = ModelConnectionController()
        var attempts = 0
        var completion: CheckedContinuation<Void, Never>?
        var verificationFinished = false
        controller.run {
            attempts += 1
            throw KeychainStoreError(operation: .read, status: errSecAuthFailed)
        }
        try await finish(controller)
        controller.recoverCredentials(using: {
            await withCheckedContinuation { completion = $0 }
            verificationFinished = true
        })
        for _ in 0..<200 where completion == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        let pending = try XCTUnwrap(completion)
        controller.cancel()
        pending.resume()
        for _ in 0..<200 where controller.recoveringCredentials { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(verificationFinished)
        XCTAssertFalse(controller.recoveringCredentials)
        XCTAssertEqual(attempts, 1)
    }

    @MainActor private func finish(_ controller: ModelConnectionController) async throws {
        for _ in 0..<200 where controller.busy { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(controller.busy)
    }
}
