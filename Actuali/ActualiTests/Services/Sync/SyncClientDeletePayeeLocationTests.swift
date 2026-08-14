import Foundation
import GRDB
import Testing
@testable import Actuali

/// Deleting a payee location must tombstone the local row optimistically and
/// replicate exactly one tombstone CRDT message (upstream's soft-delete shape).
struct SyncClientDeletePayeeLocationTests {

    /// messages_crdt normally comes from the downloaded budget file, so create
    /// it with the upstream schema; payee_locations comes from our migration.
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                )
                """)
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    /// Sync client wired to a real database. The server client is
    /// unconfigured, so the post-write automatic sync fails fast and locally
    /// without touching the network.
    private func makeSyncClient(database: BudgetDatabase) async throws -> SyncClient {
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        return syncClient
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func deleteTombstonesRowAndEmitsSingleMessage() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let location = PayeeLocation(
            id: "loc-1", payeeId: "p1", latitude: -33.85, longitude: 151.21,
            createdAt: 1_751_760_000_000)
        try database.insertPayeeLocation(location)
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.deletePayeeLocation(location)

        let queue = try DatabaseQueue(path: path.path)
        let tombstone = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT tombstone FROM payee_locations WHERE id = 'loc-1'")
        }
        #expect(tombstone == 1)

        let messages = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messages_crdt ORDER BY timestamp")
        }
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message["dataset"] == "payee_locations")
        #expect(message["row"] == "loc-1")
        #expect(message["column"] == "tombstone")
        #expect(message["value"] == "N:1")
    }

    @Test func deleteThrowsWhenNotConfigured() async throws {
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        let location = PayeeLocation(id: "loc-1", payeeId: "p1", latitude: 0, longitude: 0, createdAt: 1)
        await #expect(throws: SyncError.self) {
            try await syncClient.deletePayeeLocation(location)
        }
    }
}
