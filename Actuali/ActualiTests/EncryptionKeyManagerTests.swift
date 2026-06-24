import Foundation
import Testing
import CryptoKit
@testable import Actuali

struct EncryptionKeyManagerTests {

    private struct Fixture: Codable {
        let password: String
        let wrongPassword: String
        let salt: String
        let keyId: String
        let derivedKeyBase64: String
        let test: String
    }

    private func loadFixture() throws -> Fixture {
        let url = Bundle(for: BundleToken.self).url(forResource: "encryption-key-fixture", withExtension: "json")!
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    private final class BundleToken {}

    @Test func derivesKeyMatchingActualConvention() throws {
        let fx = try loadFixture()
        let key = SyncEncryption.deriveKey(password: fx.password, salt: Data(fx.salt.utf8))
        let derived = key.withUnsafeBytes { Data($0).base64EncodedString() }
        #expect(derived == fx.derivedKeyBase64)  // locks in the UTF-8-salt convention vs Actual
    }

    @Test func validatesCorrectPassword() throws {
        let fx = try loadFixture()
        let info = ServerKeyInfo(id: fx.keyId, salt: fx.salt, test: fx.test)
        let loaded = try EncryptionKeyManager.deriveAndValidate(password: fx.password, keyInfo: info)
        #expect(loaded.keyId == fx.keyId)
    }

    @Test func rejectsWrongPassword() throws {
        let fx = try loadFixture()
        let info = ServerKeyInfo(id: fx.keyId, salt: fx.salt, test: fx.test)
        #expect(throws: EncryptionKeyError.invalidPassword) {
            try EncryptionKeyManager.deriveAndValidate(password: fx.wrongPassword, keyInfo: info)
        }
    }

    @Test func rejectsLegacyNilTest() throws {
        let fx = try loadFixture()
        let info = ServerKeyInfo(id: fx.keyId, salt: fx.salt, test: nil)
        #expect(throws: EncryptionKeyError.unsupportedLegacyKey) {
            try EncryptionKeyManager.deriveAndValidate(password: fx.password, keyInfo: info)
        }
    }

    @Test func keychainRoundTrip() throws {
        let fileId = "test-file-\(UUID().uuidString)"
        let loaded = LoadedKey(keyId: "kid", key: SymmetricKey(size: .bits256))
        try EncryptionKeyManager.store(loaded, fileId: fileId)
        let fetched = EncryptionKeyManager.load(fileId: fileId)
        #expect(fetched == loaded)
        try EncryptionKeyManager.remove(fileId: fileId)
        #expect(EncryptionKeyManager.load(fileId: fileId) == nil)
    }
}
