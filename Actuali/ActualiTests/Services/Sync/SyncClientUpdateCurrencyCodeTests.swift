import Foundation
import GRDB
import Testing
@testable import Actuali

/// Pins `updateCurrencyCode()`: a user picking a currency in Settings must
/// land in the budget's own `preferences` table as Actual's
/// `defaultCurrencyCode` row and be replicated as a CRDT message, so the
/// choice survives a relaunch and reaches other clients (GH #59). Mirrors
/// upstream `saveSyncedPrefs` (loot-core/src/server/preferences/app.ts).
struct SyncClientUpdateCurrencyCodeTests {

    /// The preferences table and messages_crdt normally come from the
    /// downloaded budget file, so create them with the upstream schema.
    private func makeDatabase(withPreferencesTable: Bool = true) throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            if withPreferencesTable {
                try db.execute(sql: """
                    CREATE TABLE preferences (
                        id TEXT PRIMARY KEY,
                        value TEXT
                    )
                    """)
            }
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

    private func messageRows(path: URL) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messages_crdt ORDER BY timestamp")
        }
    }

    @Test func writesPreferencesRowAndEmitsMessage() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.updateCurrencyCode("EUR")

        // The row the app's own load path reads back on relaunch.
        let stored = try await database.fetchCurrencyCode()
        #expect(stored == "EUR")

        // One replicated message, shaped exactly like upstream saveSyncedPrefs
        // (dataset "preferences", row = pref key, column "value").
        let messages = try messageRows(path: path)
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message["dataset"] == "preferences")
        #expect(message["row"] == "defaultCurrencyCode")
        #expect(message["column"] == "value")
        #expect(message["value"] == "S:EUR")
    }

    @Test func secondChangeOverwritesRowInPlace() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.updateCurrencyCode("EUR")
        try await syncClient.updateCurrencyCode("NZD")

        let stored = try await database.fetchCurrencyCode()
        #expect(stored == "NZD")

        // Still a single preferences row, but both edits replicated so other
        // clients converge on the latest by timestamp.
        let queue = try DatabaseQueue(path: path.path)
        let rowCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM preferences") ?? 0
        }
        #expect(rowCount == 1)
        #expect(try messageRows(path: path).count == 2)
    }

    @Test func missingPreferencesTableStillRecordsMessage() async throws {
        // Budgets from servers that predate the preferences migration: the
        // local apply is skipped (unknown schema), but the message must still
        // be recorded in messages_crdt so it replays after a migration and
        // reaches the server.
        let (database, path) = try makeDatabase(withPreferencesTable: false)
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.updateCurrencyCode("EUR")

        #expect(try messageRows(path: path).count == 1)
    }
}
