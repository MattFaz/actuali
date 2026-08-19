import Foundation
import Testing
import CryptoKit
@testable import Actuali

struct SyncEncoderTests {

    private func sampleMessage() -> CRDTMessage {
        CRDTMessage(
            timestamp: HLCTimestamp.parse("2026-06-24T00:00:00.000Z-0000-0123456789abcdef")!,
            dataset: "transactions", row: "row-1", column: "amount", value: "S:100"
        )
    }

    @Test func encodesKeyIdAndEncryptsWhenKeyPresent() throws {
        let key = SymmetricKey(size: .bits256)
        let encoder = SyncEncoder(encryptionKey: key)
        let data = try encoder.encode(
            messages: [sampleMessage()], fileId: "f1", groupId: "g1", keyId: "kid-1", since: "0"
        )
        let request = try SyncRequest(serializedData: data)
        #expect(request.keyID == "kid-1")
        #expect(request.messages.first?.isEncrypted == true)
    }

    @Test func plaintextWhenNoKey() throws {
        let encoder = SyncEncoder()
        let data = try encoder.encode(
            messages: [sampleMessage()], fileId: "f1", groupId: "g1", keyId: nil, since: "0"
        )
        let request = try SyncRequest(serializedData: data)
        #expect(request.messages.first?.isEncrypted == false)
    }
}
