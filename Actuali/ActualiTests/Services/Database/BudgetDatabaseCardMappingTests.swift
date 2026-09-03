import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins `fetchCardAccountMappings()` against the SQLite `preferences` table.
/// Stored under `actuali:card_mappings` as a JSON dictionary `[keyword: accountId]`.
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

        let mappings = ["1234": "acct_chase", "HSBC": "acct_hsbc"]
        let data = try JSONEncoder().encode(mappings)
        let json = String(decoding: data, as: UTF8.self)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: [BudgetDatabase.cardMappingsPreferenceKey, json]
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

    @Test func fetchCardAccountMappingsReturnsEmptyWhenMissingOrInvalid() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        // Missing key
        let missing = try await db.fetchCardAccountMappings()
        #expect(missing.isEmpty)

        // NULL value
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, NULL)",
                arguments: [BudgetDatabase.cardMappingsPreferenceKey]
            )
        }
        let nullValue = try await db.fetchCardAccountMappings()
        #expect(nullValue.isEmpty)

        // Invalid JSON
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(
                sql: "UPDATE preferences SET value = ? WHERE id = ?",
                arguments: ["{invalid_json}", BudgetDatabase.cardMappingsPreferenceKey]
            )
        }
        let corruptValue = try await db.fetchCardAccountMappings()
        #expect(corruptValue.isEmpty)
    }
}
