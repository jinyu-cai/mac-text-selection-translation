import Foundation
import Security

struct KeychainStoreError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "钥匙串\(operation)失败：\(detail)"
    }
}

/// Minimal generic-password storage so API keys live in the user's Keychain
/// instead of plaintext UserDefaults.
enum KeychainStore {
    private static let service = "Text Selection Translation"

    enum Account {
        static let microsoftTranslatorKey = "microsoft-translator-key"

        static func backendKey(_ id: UUID) -> String {
            "backend-key-" + id.uuidString
        }
    }

    static func string(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainStoreError(operation: "读取", status: status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError(operation: "解码", status: errSecDecode)
        }
        return value
    }

    /// Saves `value` for `account`; an empty value removes the entry.
    static func set(_ value: String, for account: String) throws {
        guard !value.isEmpty else {
            try delete(account: account)
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var attributes = baseQuery(account: account)
            attributes[kSecValueData as String] = data
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError(operation: "写入", status: addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainStoreError(operation: "更新", status: status)
        }
    }

    static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(operation: "删除", status: status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
