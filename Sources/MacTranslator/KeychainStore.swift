import Foundation
import Security

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

    static func string(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `value` for `account`; an empty value removes the entry.
    static func set(_ value: String, for account: String) {
        guard !value.isEmpty else {
            delete(account: account)
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
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
