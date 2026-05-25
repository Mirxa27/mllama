import Foundation
import Security

/// Tiny strongly-typed wrapper around Keychain Services for storing secrets
/// that survive across launches without sitting in plaintext UserDefaults.
///
/// All entries are scoped to `kSecAttrAccessibleAfterFirstUnlock` — i.e.,
/// readable once the user has logged in since boot, which matches a desktop
/// app that may need to refresh tokens in the background after a system
/// reboot but before the user has unlocked the keychain manually.
///
/// Access pattern is purely service+account; nothing else (e.g., access
/// groups for App Store sharing) since Mllama isn't part of an app group.
enum KeychainStore {

    private static let service = "org.mllama.app"

    enum KeychainError: Error, CustomStringConvertible {
        case osStatus(OSStatus)
        case encoding

        var description: String {
            switch self {
            case .osStatus(let s): return "Keychain error: OSStatus \(s)"
            case .encoding:        return "Keychain: failed to encode string"
            }
        }
    }

    // MARK: - String API

    /// Write a string under `account`. If a value already exists, it's
    /// replaced atomically (delete + add). Pass `nil` to remove.
    static func set(_ value: String?, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Always delete the existing item to avoid the "duplicate item"
        // OSStatus and to handle accessibility-flag migrations cleanly.
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        guard let data = value.data(using: .utf8) else { throw KeychainError.encoding }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    /// Read the string stored under `account`. Returns nil if no entry.
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// True if a value exists under `account` (without copying it).
    static func has(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Known accounts

extension KeychainStore {
    /// Stable account names for each secret Mllama keeps in the keychain.
    enum Account {
        static let huggingFaceToken = "hf.token"
    }

    // MARK: HuggingFace token convenience

    /// Read the HF token, falling back to legacy UserDefaults storage so
    /// users who set it in older builds aren't suddenly logged out. After
    /// a successful read from UserDefaults, the value is migrated into the
    /// keychain and removed from UserDefaults.
    static func huggingFaceToken() -> String? {
        if let v = get(account: Account.huggingFaceToken) { return v }
        // Legacy path: was stored under HFKeys.token in UserDefaults.
        let legacy = UserDefaults.standard.string(forKey: HFKeys.token) ?? ""
        if !legacy.isEmpty {
            try? set(legacy, account: Account.huggingFaceToken)
            UserDefaults.standard.removeObject(forKey: HFKeys.token)
            Log.hf.info("Migrated HF token from UserDefaults to Keychain.")
            return legacy
        }
        return nil
    }

    /// Persist the user-supplied HF token. Pass nil/empty to clear.
    static func setHuggingFaceToken(_ token: String?) throws {
        try set(token, account: Account.huggingFaceToken)
    }
}
