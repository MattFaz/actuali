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
    private func makeDatabase(withPreferencesTable: Bool = true) async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase((withPreferencesTable ? [TestSchema.preferences] : []) + [TestSchema.messagesCrdt])
    }

    // Sync client wired to a real database. The server client is
    // unconfigured, so the post-write automatic sync fails fast and locally
    // without touching the network.

    @Test func writesPreferencesRowAndEmitsMessage() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeTestSyncClient(database: database)

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
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeTestSyncClient(database: database)

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
        let (database, path) = try await makeDatabase(withPreferencesTable: false)
        defer { cleanup(path) }
        let syncClient = try await makeTestSyncClient(database: database)

        try await syncClient.updateCurrencyCode("EUR")

        #expect(try messageRows(path: path).count == 1)
    }
}
