import Foundation
import GRDB
import Testing
@testable import Actuali

/// Pins `setCardAccountMappings()` on `SyncClient`.
/// Verifies that card mappings are written locally to SQLite preferences,
/// generate valid CRDT messages in `messages_crdt`, and clear when empty.
@MainActor
struct SyncClientCardMappingTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE preferences (
                    id TEXT PRIMARY KEY,
                    value TEXT
                );
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                );
                """)
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func makeSyncClient(database: BudgetDatabase) async throws -> SyncClient {
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        return syncClient
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func messageRows(path: URL) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messages_crdt ORDER BY timestamp")
        }
    }

    @Test func writesCardMappingsRowAndEmitsCRDTMessage() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        let client = try await makeSyncClient(database: database)
        let mappings = ["1234": "acct_chase", "HSBC": "acct_hsbc"]

        try await client.setCardAccountMappings(mappings)

        let fetched = try await database.fetchCardAccountMappings()
        #expect(fetched["1234"] == "acct_chase")
        #expect(fetched["HSBC"] == "acct_hsbc")

        let messages = try messageRows(path: path)
        #expect(messages.count == 1)
        #expect(messages[0]["dataset"] == "preferences")
        #expect(messages[0]["row"] == BudgetDatabase.cardMappingsPreferenceKey)
        #expect(messages[0]["column"] == "value")
    }

    @Test func emptyMappingsClearsRowAndEmitsNullMessage() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        let client = try await makeSyncClient(database: database)

        // Write then clear
        try await client.setCardAccountMappings(["1234": "acct_chase"])
        try await client.setCardAccountMappings([:])

        let fetched = try await database.fetchCardAccountMappings()
        #expect(fetched.isEmpty)

        let messages = try messageRows(path: path)
        #expect(messages.count == 2)
        #expect(messages[1]["row"] == BudgetDatabase.cardMappingsPreferenceKey)
        #expect(messages[1]["column"] == "value")
        #expect(messages[1]["value"] == "0:") // Null CRDT value representation
    }
}
