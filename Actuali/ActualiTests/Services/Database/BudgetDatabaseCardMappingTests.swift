import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins `fetchCardAccountMappings()` against the SQLite `preferences` table.
@MainActor
struct BudgetDatabaseCardMappingTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT)")
        }
        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func fetchCardAccountMappingsReturnsDecodedMappings() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: [BudgetDatabase.cardMappingPreferenceKey(for: "1234"), "acct_chase"]
            )
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: [BudgetDatabase.cardMappingPreferenceKey(for: "HSBC"), "acct_hsbc"]
            )
            // Unrelated preference
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: ["defaultCurrencyCode", "USD"]
            )
        }

        let fetched = try await db.fetchCardAccountMappings()
        #expect(fetched.count == 2)
        #expect(fetched["1234"] == "acct_chase")
        #expect(fetched["HSBC"] == "acct_hsbc")
    }

    @Test func fetchCardAccountMappingsReturnsEmptyWhenMissingOrCleared() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        // Missing key
        let missing = try await db.fetchCardAccountMappings()
        #expect(missing.isEmpty)

        // NULL value
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, NULL)",
                arguments: [BudgetDatabase.cardMappingPreferenceKey(for: "1234")]
            )
        }
        let nullValue = try await db.fetchCardAccountMappings()
        #expect(nullValue.isEmpty)

    }
}
