import Foundation
import LocalAuthentication
import Security

struct KeychainStoreError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        if status == errSecInteractionNotAllowed {
            return """
            为避免登录时反复弹出密码窗口，应用已跳过需要重新授权的旧版钥匙串项目。\
            请在设置中重新输入对应的 API Key。
            """
        }
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "钥匙串\(operation)失败：\(detail)"
    }
}

/// Minimal generic-password storage so API keys live in the user's Keychain
/// instead of plaintext UserDefaults.
enum KeychainStore {
    enum Interaction {
        case allow
        case suppress
    }

    /// Versioned service name keeps new writes separate from entries created by
    /// older ad-hoc-signed builds. Those entries may carry a stale application
    /// ACL that otherwise asks for the login password once per API key.
    private static let service = "com.example.mactranslator.credentials.v2"
    private static let legacyService = "Text Selection Translation"

    enum Account {
        static let microsoftTranslatorKey = "microsoft-translator-key"

        static func backendKey(_ id: UUID) -> String {
            "backend-key-" + id.uuidString
        }
    }

    static func string(
        for account: String,
        interaction: Interaction = .allow
    ) throws -> String? {
        if let value = try string(
            for: account,
            service: service,
            interaction: interaction
        ) {
            return value
        }

        // Silently migrate an accessible legacy item. When the old ACL would
        // require a password dialog, a suppressed launch-time lookup fails
        // cleanly instead of presenting one dialog for every configured backend.
        guard let legacyValue = try string(
            for: account,
            service: legacyService,
            interaction: interaction
        ) else {
            return nil
        }
        try? set(legacyValue, for: account, interaction: interaction)
        return legacyValue
    }

    private static func string(
        for account: String,
        service: String,
        interaction: Interaction
    ) throws -> String? {
        var query = baseQuery(account: account, service: service)
        configureAuthenticationUI(in: &query, interaction: interaction)
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
    static func set(
        _ value: String,
        for account: String,
        interaction: Interaction = .allow
    ) throws {
        guard !value.isEmpty else {
            try delete(account: account, interaction: interaction)
            return
        }
        let data = Data(value.utf8)
        var query = baseQuery(account: account, service: service)
        configureAuthenticationUI(in: &query, interaction: interaction)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var attributes = baseQuery(account: account, service: service)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError(operation: "写入", status: addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainStoreError(operation: "更新", status: status)
        }
    }

    static func delete(
        account: String,
        interaction: Interaction = .allow
    ) throws {
        var query = baseQuery(account: account, service: service)
        configureAuthenticationUI(in: &query, interaction: interaction)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(operation: "删除", status: status)
        }
    }

    private static func baseQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func configureAuthenticationUI(
        in query: inout [String: Any],
        interaction: Interaction
    ) {
        if interaction == .suppress {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
    }
}
