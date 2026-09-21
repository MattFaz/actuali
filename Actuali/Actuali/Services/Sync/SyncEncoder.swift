// Actuali/Actuali/Services/Sync/SyncEncoder.swift

import CryptoKit
import Foundation

enum SyncEncoderError: Error {
    case encodingFailed
    case decodingFailed
    case encryptionRequired
    case invalidTimestamp
    case invalidMerkle
}

/// Encodes/decodes sync messages to/from Protobuf
struct SyncEncoder {
    private let encryptionKey: SymmetricKey?

    init(encryptionKey: SymmetricKey? = nil) {
        self.encryptionKey = encryptionKey
    }

    // MARK: - Encode Request

    func encode(
        messages: [CRDTMessage],
        fileId: String,
        groupId: String,
        keyId: String?,
        since: String
    ) throws -> Data {
        var request = SyncRequest()
        request.fileID = fileId
        request.groupID = groupId
        request.keyID = keyId ?? ""
        request.since = since

        for msg in messages {
            var envelope = MessageEnvelope()
            envelope.timestamp = msg.timestamp.toString()

            // Create inner message
            var inner = Message()
            inner.dataset = msg.dataset
            inner.row = msg.row
            inner.column = msg.column
            inner.value = msg.value

            let innerData = try inner.serializedData()

            // Encrypt if key is available
            if let key = encryptionKey {
                let encrypted = try SyncEncryption.encrypt(innerData, using: key)
                envelope.isEncrypted = true
                envelope.content = try encrypted.serializedData()
            } else {
                envelope.isEncrypted = false
                envelope.content = innerData
            }

            request.messages.append(envelope)
        }

        return try request.serializedData()
    }

    // MARK: - Decode Response

    func decode(_ data: Data) throws -> (messages: [CRDTMessage], merkle: MerkleNode) {
        let response = try SyncResponse(serializedData: data)

        // Parse merkle tree from JSON (server sends hash as signed Int32)
        guard let merkleData = response.merkle.data(using: .utf8),
              let merkle = try? JSONDecoder().decode(MerkleNode.self, from: merkleData) else {
            throw SyncEncoderError.invalidMerkle
        }

        var messages: [CRDTMessage] = []

        for envelope in response.messages {
            let innerData: Data

            if envelope.isEncrypted {
                guard let key = encryptionKey else {
                    throw SyncEncoderError.encryptionRequired
                }
                let encrypted = try EncryptedData(serializedData: envelope.content)
                innerData = try SyncEncryption.decrypt(encrypted, using: key)
            } else {
                innerData = envelope.content
            }

            let inner = try Message(serializedData: innerData)

            guard let timestamp = HLCTimestamp.parse(envelope.timestamp) else {
                throw SyncEncoderError.invalidTimestamp
            }

            messages.append(CRDTMessage(
                timestamp: timestamp,
                dataset: inner.dataset,
                row: inner.row,
                column: inner.column,
                value: inner.value
            ))
        }

        return (messages, merkle)
    }
}
