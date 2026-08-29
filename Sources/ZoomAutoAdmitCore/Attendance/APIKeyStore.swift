import Foundation
import Security

/// The OpenRouter API key, kept in the macOS Keychain.
///
/// Never written to `schedules.json`, never placed in a log line, never held in
/// a source file. The only thing that leaves this type is the key itself, and
/// only to the request that needs it.
public enum APIKeyStore {
    public static let service = "com.mohamedhosam.ZoomAutoAdmit.OpenRouter"
    private static let account = "api-key"

    public static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete() }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        // Available after first unlock, so a scheduled meeting can reconcile
        // without the user being at the keyboard.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    @discardableResult
    public static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    public static var hasKey: Bool { load() != nil }

    /// Safe for logs and for the UI: reveals only enough to recognise the key.
    public static func redacted(_ key: String?) -> String {
        guard let key, key.count > 8 else { return "not set" }
        return "••••••••" + key.suffix(4)
    }
}
