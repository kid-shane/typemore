import Foundation
import Security

/// API Key 存储在 macOS Keychain，而不是明文写入 settings.json。
enum KeychainStore {
    private static let service = "Typemore"
    private static let legacyAccount = "default-api-key"

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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return deleteAPIKey(account: account)
        }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
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
