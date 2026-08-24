import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins `fetchCreditCardConfigs()` and `fetchPreferences(prefix:)` against the
/// SQLite `preferences` table. Preferences are keyed by a unique namespace
/// (e.g. `actuali:credit_card:<accountId>`) to safely coexist with upstream
/// Actual preferences without schema alterations.
@MainActor
struct BudgetDatabaseCreditCardTests {

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

    @Test func fetchCreditCardConfigsReturnsDecodedConfigs() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        let chaseConfig = CreditCardConfig(statementDay: 18, dueOffsetDays: 25, limit: 500000)
        let appleConfig = CreditCardConfig(statementDay: 31, dueOffsetDays: 15, limit: nil)

        let chaseData = try JSONEncoder().encode(chaseConfig)
        let appleData = try JSONEncoder().encode(appleConfig)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: ["actuali:credit_card:acct_chase", String(data: chaseData, encoding: .utf8)]
            )
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: ["actuali:credit_card:acct_apple", String(data: appleData, encoding: .utf8)]
            )
            // Unrelated upstream preference row that should be ignored
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: ["defaultCurrencyCode", "USD"]
            )
        }

        let configs = try await db.fetchCreditCardConfigs()
        #expect(configs.count == 2)

        let chase = try #require(configs["acct_chase"])
        #expect(chase.statementDay == 18)
        #expect(chase.dueOffsetDays == 25)
        #expect(chase.limit == 500000)

        let apple = try #require(configs["acct_apple"])
        #expect(apple.statementDay == 31)
        #expect(apple.dueOffsetDays == 15)
        #expect(apple.limit == nil)
    }

    @Test func fetchCreditCardConfigsIgnoresNullEmptyAndInvalidRows() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            // Cleared / deleted card (NULL)
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, NULL)",
                arguments: ["actuali:credit_card:acct_null"]
            )
            // Empty string
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, '')",
                arguments: ["actuali:credit_card:acct_empty"]
            )
            // Invalid JSON
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: ["actuali:credit_card:acct_corrupt", "{invalid_json}"]
            )
        }

        let configs = try await db.fetchCreditCardConfigs()
        #expect(configs.isEmpty)
    }

    @Test func fetchPreferencesReturnsPrefixFilteredDictionary() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO preferences (id, value) VALUES
                    ('actuali:custom:item1', 'value1'),
                    ('actuali:custom:item2', 'value2'),
                    ('other_prefix:item',   'value3');
            """)
        }

        let prefixed = try await db.fetchPreferences(prefix: "actuali:custom:")
        #expect(prefixed.count == 2)
        #expect(prefixed["item1"] == "value1")
        #expect(prefixed["item2"] == "value2")
        #expect(prefixed["item"] == nil)
    }
}
