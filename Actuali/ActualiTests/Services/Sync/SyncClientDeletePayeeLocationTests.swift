import Foundation
import GRDB
import Testing
@testable import Actuali

/// Deleting a payee location must tombstone the local row optimistically and
/// replicate exactly one tombstone CRDT message (upstream's soft-delete shape).
struct SyncClientDeletePayeeLocationTests {
    // Sync client wired to a real database. The server client is
    // unconfigured, so the post-write automatic sync fails fast and locally
    // without touching the network.

    @Test func deleteTombstonesRowAndEmitsSingleMessage() async throws {
        // messages_crdt normally comes from the downloaded budget file;
        // payee_locations comes from our migration.
        let (database, path) = try await makeTestDatabase(TestSchema.messagesCrdt)
        defer { cleanup(path) }
        let location = PayeeLocation(
            id: "loc-1", payeeId: "p1", latitude: -33.85, longitude: 151.21,
            createdAt: 1_751_760_000_000
        )
        try database.insertPayeeLocation(location)
        let syncClient = try await makeTestSyncClient(database: database)

        try await syncClient.deletePayeeLocation(location)

        let queue = try DatabaseQueue(path: path.path)
        let tombstone = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT tombstone FROM payee_locations WHERE id = 'loc-1'")
        }
        #expect(tombstone == 1)

        let messages = try await queue.read { db -> [(dataset: String, row: String, column: String, value: String)] in
            try Row.fetchAll(db, sql: "SELECT * FROM messages_crdt ORDER BY timestamp")
                .map { (dataset: $0["dataset"], row: $0["row"], column: $0["column"], value: $0["value"]) }
        }
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message.dataset == "payee_locations")
        #expect(message.row == "loc-1")
        #expect(message.column == "tombstone")
        #expect(message.value == "N:1")
    }

    @Test func deleteThrowsWhenNotConfigured() async throws {
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        let location = PayeeLocation(id: "loc-1", payeeId: "p1", latitude: 0, longitude: 0, createdAt: 1)
        await #expect(throws: SyncError.self) {
            try await syncClient.deletePayeeLocation(location)
        }
    }
}
