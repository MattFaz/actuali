// Actuali/Actuali/Services/Sync/EncryptionKeyManager.swift

import Foundation
import CryptoKit

/// Server response from POST /user-get-key.
struct ServerKeyInfo: Codable, Sendable {
    let id: String
    let salt: String
    let test: String?   // JSON string {value, meta:{keyId,algorithm,iv,authTag}}, or nil for legacy keys
}

/// A validated, in-memory encryption key for a budget.
struct LoadedKey: Equatable, Sendable {
    let keyId: String
    let key: SymmetricKey
}

enum EncryptionKeyError: LocalizedError {
    case invalidPassword
    case unsupportedLegacyKey
    case malformedTestMessage

    var errorDescription: String? {
        switch self {
        case .invalidPassword:      return "Incorrect encryption password."
        case .unsupportedLegacyKey: return "This budget uses an old encryption format that isn't supported."
        case .malformedTestMessage: return "The server returned an unreadable encryption key test."
        }
    }
}

/// Derives, validates, persists, and retrieves a budget's E2EE key.
/// Persists the derived key (never the password) in the Keychain, keyed by fileId.
enum EncryptionKeyManager {

    private struct StoredKey: Codable { let keyId: String; let base64Key: String }
    private struct TestMessage: Codable {
        let value: String
        let meta: Meta
        struct Meta: Codable { let keyId: String; let algorithm: String; let iv: String; let authTag: String }
    }

    private static func keychainKey(fileId: String) -> String { "encryptKey.\(fileId)" }

    /// Derive the key from the password + server salt and validate it against the test message.
    static func deriveAndValidate(password: String, keyInfo: ServerKeyInfo) throws -> LoadedKey {
        guard let testJSON = keyInfo.test else { throw EncryptionKeyError.unsupportedLegacyKey }
        guard let testData = testJSON.data(using: .utf8),
              let test = try? JSONDecoder().decode(TestMessage.self, from: testData),
              let ciphertext = Data(base64Encoded: test.value) else {
            throw EncryptionKeyError.malformedTestMessage
        }

        // CRITICAL: salt is the UTF-8 bytes of the base64 salt string (matches Actual's Buffer.from(salt)).
        let key = SyncEncryption.deriveKey(password: password, salt: Data(keyInfo.salt.utf8))

        do {
            _ = try SyncEncryption.decrypt(
                ciphertext: ciphertext,
                ivBase64: test.meta.iv,
                authTagBase64: test.meta.authTag,
                using: key
            )
        } catch {
            throw EncryptionKeyError.invalidPassword
        }
        return LoadedKey(keyId: keyInfo.id, key: key)
    }

    static func store(_ loaded: LoadedKey, fileId: String) throws {
        let stored = StoredKey(keyId: loaded.keyId, base64Key: loaded.key.withUnsafeBytes { Data($0).base64EncodedString() })
        let json = String(data: try JSONEncoder().encode(stored), encoding: .utf8)!
        try Keychain.set(json, for: keychainKey(fileId: fileId))
    }

    static func load(fileId: String) -> LoadedKey? {
        guard let json = Keychain.get(for: keychainKey(fileId: fileId)),
              let data = json.data(using: .utf8),
              let stored = try? JSONDecoder().decode(StoredKey.self, from: data),
              let keyData = Data(base64Encoded: stored.base64Key) else {
            return nil
        }
        return LoadedKey(keyId: stored.keyId, key: SymmetricKey(data: keyData))
    }

    static func remove(fileId: String) throws {
        try Keychain.remove(for: keychainKey(fileId: fileId))
    }
}
