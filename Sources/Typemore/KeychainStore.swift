import Foundation
import Security

struct KeychainStoreError: LocalizedError {
    enum Operation: String {
        case read = "读取"
        case save = "保存"
        case delete = "删除"
        case authenticate = "验证"
    }

    let operation: Operation
    let status: OSStatus

    var errorDescription: String? {
        let reason: String
        switch status {
        case errSecAuthFailed: reason = "macOS 暂时无法访问已保存的凭据"
        case errSecInteractionNotAllowed: reason = "macOS 钥匙串需要解锁或允许访问"
        case errSecUserCanceled: reason = "钥匙串授权已取消"
        case errSecDecode: reason = "钥匙串中的凭据数据无法读取"
        default: reason = "钥匙串\(operation.rawValue)失败"
        }
        return "\(reason)（\(status)）"
    }

    var recoverySuggestion: String? {
        switch status {
        case errSecAuthFailed:
            return "Typemore 使用 macOS 钥匙串安全保存登录状态和 API Key。点击“恢复连接”，按系统提示验证后会自动重试。"
        case errSecInteractionNotAllowed:
            return "点击“恢复连接”，在 macOS 系统窗口中解锁钥匙串并允许 Typemore 访问，然后会自动重试。"
        case errSecUserCanceled:
            return "点击“恢复连接”，在 macOS 系统窗口中完成验证后会自动重试。"
        default: return nil
        }
    }
}

/// API Key 与登录凭据保存在 macOS Keychain。
enum KeychainStore {
    private static let service = "Typemore"
    private static let legacyAccount = "default-api-key"

    /// 仅在用户确认恢复后调用；密码由 macOS 系统窗口接收。
    static func reauthenticate() async throws {
        try await Task.detached(priority: .userInitiated) {
            var keychain: SecKeychain?
            let status = SecKeychainCopyDefault(&keychain)
            guard status == errSecSuccess, let keychain else {
                throw KeychainStoreError(operation: .authenticate,
                                         status: status == errSecSuccess ? errSecNoSuchKeychain : status)
            }
            try reauthenticate(lock: { SecKeychainLock(keychain) },
                               unlock: { SecKeychainUnlock(keychain, 0, nil, false) })
        }.value
    }

    static func reauthenticate(lock: () -> OSStatus, unlock: () -> OSStatus) throws {
        let lockStatus = lock()
        guard lockStatus == errSecSuccess else {
            throw KeychainStoreError(operation: .authenticate, status: lockStatus)
        }
        // 锁定后立即进入系统解锁流程，保留系统弹窗中的取消操作。
        let unlockStatus = unlock()
        guard unlockStatus == errSecSuccess else {
            throw KeychainStoreError(operation: .authenticate, status: unlockStatus)
        }
    }

    static func readSecret(_ account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError(operation: .read, status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError(operation: .read, status: errSecDecode)
        }
        return value
    }

    static func writeSecret(_ account: String, _ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = baseQuery(account: account)
        if trimmed.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainStoreError(operation: .delete, status: status)
            }
            return
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainStoreError(operation: .save, status: status) }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError(operation: .save, status: addStatus)
        }
    }

    static func loadAPIKey() -> String {
        loadAPIKey(account: legacyAccount)
    }

    static func loadAPIKey(for provider: Provider) -> String {
        loadAPIKey(account: account(for: provider))
    }

    private static func loadAPIKey(account: String) -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    @discardableResult
    static func saveAPIKey(_ value: String) -> Bool {
        saveAPIKey(value, account: legacyAccount)
    }

    @discardableResult
    static func saveAPIKey(_ value: String, for provider: Provider) -> Bool {
        saveAPIKey(value, account: account(for: provider))
    }

    @discardableResult
    private static func saveAPIKey(_ value: String, account: String) -> Bool {
        do { try writeSecret(account, value); return true }
        catch { return false }
    }

    @discardableResult
    static func deleteAPIKey() -> Bool {
        deleteAPIKey(account: legacyAccount)
    }

    @discardableResult
    static func deleteAPIKey(for provider: Provider) -> Bool {
        deleteAPIKey(account: account(for: provider))
    }

    @discardableResult
    static func deleteAllAPIKeys() -> Bool {
        [Provider.volcengine, .compatible].allSatisfy { deleteAPIKey(for: $0) } && deleteAPIKey()
    }

    @discardableResult
    private static func deleteAPIKey(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func account(for provider: Provider) -> String {
        "api-key-\(provider.rawValue)"
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
