import Foundation
import Security

/// Storage for sensitive strings (Integration API key, classic-API username
/// and password). `KeychainSecretStore` is the real one; tests use an
/// in-memory store so they never touch the Keychain.
protocol SecretStoring {
    func get(_ account: String) -> String?
    @discardableResult func set(_ value: String, account: String) -> Bool
    @discardableResult func remove(_ account: String) -> Bool
}

struct KeychainSecretStore: SecretStoring {
    func get(_ account: String) -> String? { KeychainStore.get(account) }
    func set(_ value: String, account: String) -> Bool { KeychainStore.set(value, account: account) }
    func remove(_ account: String) -> Bool { KeychainStore.remove(account) }
}

/// Thin wrapper over the macOS Keychain for storing sensitive strings
/// (Integration API key, classic-API username/password) as generic password
/// items, so credentials are no longer kept in plaintext UserDefaults.
enum KeychainStore {
    private static let service = "com.cb.quickprotect"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            // "Not found" is the normal first-run answer; anything else (access
            // denied for a re-signed build, locked keychain) must be visible in
            // the log rather than look like an unconfigured app.
            if status != errSecItemNotFound { _ = check(status, "read", account) }
            return nil
        }
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    /// Stores `value` for `account`. An empty string removes the item entirely.
    /// Returns false when the Keychain refused the write (the status is logged).
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        guard !value.isEmpty else { return remove(account) }

        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // AfterFirstUnlock so credentials are available when the app relaunches
            // at login; ThisDeviceOnly so they never sync or migrate via backups.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        var status = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery(account)
            insert.merge(attributes) { _, new in new }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        return check(status, "store", account)
    }

    /// Removes the item. Returns true when it is gone (including "was never there").
    @discardableResult
    static func remove(_ account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        return status == errSecItemNotFound || check(status, "remove", account)
    }

    private static func check(_ status: OSStatus, _ op: String, _ account: String) -> Bool {
        guard status != errSecSuccess else { return true }
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        NSLog("[Keychain] %@ %@ failed: %@", op, account, reason)
        return false
    }
}
