import Foundation
import os
import Security

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "Keychain")

enum KeychainError: Error {
    case unhandled(OSStatus)
}

/// Minimal Keychain wrapper for storing small secrets (auth tokens etc).
///
/// - Uses `kSecClassGenericPassword` under service `com.mfazz.Actuali`.
/// - Items are accessible `kSecAttrAccessibleAfterFirstUnlock` so background
///   sync can read them after reboot + first unlock.
enum Keychain {
    private static let service = "com.mfazz.Actuali"

    /// Idempotent upsert: deletes any existing item then adds the new value.
    static func set(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unhandled(errSecParam)
        }

        // Delete any existing item (ignore not-found)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        if deleteStatus != errSecSuccess, deleteStatus != errSecItemNotFound {
            throw KeychainError.unhandled(deleteStatus)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandled(addStatus)
        }
    }

    /// Returns the stored string, or nil on not-found / any read error.
    /// Errors (other than not-found) are logged but not thrown.
    static func get(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                logger.error("Keychain item found but could not decode as UTF-8 string")
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            logger.error("Keychain read failed with status \(status, privacy: .public)")
            return nil
        }
    }

    /// Remove the stored item. No-op if missing.
    static func remove(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            throw KeychainError.unhandled(status)
        }
    }
}
