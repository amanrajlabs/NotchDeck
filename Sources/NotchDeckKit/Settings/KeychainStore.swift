import Foundation
import Security

/// Secrets (API keys, tokens, app passwords) live in the login keychain, never in UserDefaults.
/// NotchDeck is ad-hoc signed, so after an update macOS may ask once to allow access —
/// "Always Allow" answers it for that build.
public enum KeychainStore {
    public static let defaultService = "io.github.amanrajlabs.notchdeck"

    public static func string(for account: String, service: String = defaultService) -> String? {
        var query = baseQuery(account, service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`; an empty string deletes the item. Returns false if the keychain refused.
    @discardableResult
    public static func set(_ value: String, for account: String, service: String = defaultService) -> Bool {
        if value.isEmpty { return delete(account, service: service) }
        let data = Data(value.utf8)
        let query = baseQuery(account, service)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func delete(_ account: String, service: String = defaultService) -> Bool {
        let status = SecItemDelete(baseQuery(account, service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// One-time move of a secret that older builds kept in UserDefaults under `key`
    /// (the keychain account uses the same name). The plaintext copy is removed only
    /// after the keychain write succeeds. Returns the current secret, or "".
    public static func migrateFromDefaults(
        key: String, defaults: UserDefaults = .standard, service: String = defaultService
    ) -> String {
        if let legacy = defaults.string(forKey: key) {
            if legacy.isEmpty {
                defaults.removeObject(forKey: key)
            } else if set(legacy, for: key, service: service) {
                defaults.removeObject(forKey: key)
            } else {
                return legacy // keychain refused: keep the old copy rather than lose the secret
            }
        }
        return string(for: key, service: service) ?? ""
    }

    private static func baseQuery(_ account: String, _ service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
