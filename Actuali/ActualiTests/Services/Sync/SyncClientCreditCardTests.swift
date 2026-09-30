import Foundation
import GRDB
import Testing
@testable import Actuali

/// Pins `setCreditCardConfig()` and `setPreference()` on `SyncClient`.
/// Verifies that credit card configuration changes are written locally to SQLite,
/// generate valid CRDT messages in `messages_crdt` (dataset "preferences", row "actuali:credit_card:<accountId>", column "value"),
/// and properly clear/null the preference on deletion.
@MainActor
struct SyncClientCreditCardTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.preferences, TestSchema.messagesCrdt)
    }

    @Test func writesPreferencesRowAndEmitsCRDTMessage() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }

        let client = try await makeTestSyncClient(database: database)
        let config = CreditCardConfig(statementDay: 18, dueOffsetDays: 25, limit: 500_000)

        try await client.setCreditCardConfig(accountId: "acct_chase", config: config)

        // Read back from database
        let configs = try await database.fetchCreditCardConfigs()
        let stored = try #require(configs["acct_chase"])
        #expect(stored.statementDay == 18)
        #expect(stored.dueOffsetDays == 25)
        #expect(stored.limit == 500_000)

        // Verify CRDT message in messages_crdt
        let messages = try messageRows(path: path)
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message["dataset"] == "preferences")
        #expect(message["row"] == "actuali:credit_card:acct_chase")
        #expect(message["column"] == "value")
    }

    @Test func clearingConfigSetsNullInPreferencesAndEmitsNullCRDTMessage() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }

        let client = try await makeTestSyncClient(database: database)
        let config = CreditCardConfig(statementDay: 18, dueOffsetDays: 25)

        // Write then clear
        try await client.setCreditCardConfig(accountId: "acct_chase", config: config)
        try await client.setCreditCardConfig(accountId: "acct_chase", config: nil)

        let configs = try await database.fetchCreditCardConfigs()
        #expect(configs["acct_chase"] == nil)

        // Both operations emit CRDT messages to converge across clients
        let messages = try messageRows(path: path)
        #expect(messages.count == 2)
        #expect(messages[1]["row"] == "actuali:credit_card:acct_chase")
        #expect(messages[1]["column"] == "value")
        #expect(messages[1]["value"] == "0:") // Null CRDT value representation
    }

    @Test func genericSetPreferenceWritesAndEmitsMessage() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }

        let client = try await makeTestSyncClient(database: database)

        try await client.setPreference(key: "actuali:custom:flag", value: "active")

        let storedValue = try await database.dbQueueForTesting.read { conn in
            try String.fetchOne(conn, sql: "SELECT value FROM preferences WHERE id = ?", arguments: ["actuali:custom:flag"])
        }
        #expect(storedValue == "active")

        let messages = try messageRows(path: path)
        #expect(messages.count == 1)
        #expect(messages[0]["row"] == "actuali:custom:flag")
        #expect(messages[0]["value"] == "S:active")
    }

    @Test func genericSetPreferenceRollsBackWhenMessageInsertAborts() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }

        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
            CREATE TRIGGER fail_preference_message_insert
            BEFORE INSERT ON messages_crdt
            WHEN NEW.dataset = 'preferences' AND NEW.row = 'actuali:atomicity'
            BEGIN
                SELECT RAISE(ABORT, 'forced message insert failure');
            END;
            """)
        }

        let client = try await makeTestSyncClient(database: database)
        await #expect(throws: (any Error).self) {
            try await client.setPreference(key: "actuali:atomicity", value: "active")
        }

        let storedValue = try await database.dbQueueForTesting.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM preferences WHERE id = ?", arguments: ["actuali:atomicity"])
        }
        #expect(storedValue == nil)
        #expect(try messageRows(path: path).isEmpty)
    }
}
