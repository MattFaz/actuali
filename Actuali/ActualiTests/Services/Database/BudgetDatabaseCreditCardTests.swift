import Foundation
import Testing
import GRDB
@testable import Actuali

struct BudgetDatabaseCreditCardTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT)")
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    @Test func fetchCreditCardConfigsReturnsDecodedConfigs() async throws {
        let (db, fileURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let chaseConfig = CreditCardConfig(statementDay: 18, dueOffsetDays: 25, limit: 500000)
        let appleConfig = CreditCardConfig(statementDay: 31, dueOffsetDays: 15, limit: nil)

        try db.queue.write { sqlite in
            try sqlite.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: ["actuali:credit_card:acct_chase", chaseConfig.toJSONString()]
            )
            try sqlite.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: ["actuali:credit_card:acct_apple", appleConfig.toJSONString()]
            )
            // Unrelated preference row
            try sqlite.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: ["defaultCurrencyCode", "USD"]
            )
        }

        let configs = try await db.fetchCreditCardConfigs()
        #expect(configs.count == 2)
        #expect(configs["acct_chase"]?.statementDay == 18)
        #expect(configs["acct_chase"]?.dueOffsetDays == 25)
        #expect(configs["acct_chase"]?.limit == 500000)

        #expect(configs["acct_apple"]?.statementDay == 31)
        #expect(configs["acct_apple"]?.dueOffsetDays == 15)
        #expect(configs["acct_apple"]?.limit == nil)
    }

    @Test func fetchCreditCardConfigsIgnoresNullOrEmptyRows() async throws {
        let (db, fileURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try db.queue.write { sqlite in
            try sqlite.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: ["actuali:credit_card:acct_deleted", ""]
            )
            try sqlite.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, NULL)",
                arguments: ["actuali:credit_card:acct_null"]
            )
        }

        let configs = try await db.fetchCreditCardConfigs()
        #expect(configs.isEmpty)
    }

    @Test func genericFetchPreferencesByPrefix() async throws {
        let (db, fileURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try db.queue.write { sqlite in
            try sqlite.execute(
                sql: "INSERT INTO preferences (id, value) VALUES ('actuali:custom:item1', 'value1')"
            )
            try sqlite.execute(
                sql: "INSERT INTO preferences (id, value) VALUES ('actuali:custom:item2', 'value2')"
            )
            try sqlite.execute(
                sql: "INSERT INTO preferences (id, value) VALUES ('other:item', 'value3')"
            )
        }

        let single = try await db.fetchPreference(key: "actuali:custom:item1")
        #expect(single == "value1")

        let nonExistent = try await db.fetchPreference(key: "nonExistentKey")
        #expect(nonExistent == nil)

        let prefixed = try await db.fetchPreferences(prefix: "actuali:custom:")
        #expect(prefixed.count == 2)
        #expect(prefixed["item1"] == "value1")
        #expect(prefixed["item2"] == "value2")
    }
}
