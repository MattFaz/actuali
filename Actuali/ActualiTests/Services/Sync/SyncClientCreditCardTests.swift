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

    @Test func writesPreferencesRowAndEmitsCRDTMessage() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        let client = try await makeSyncClient(database: database)
        let config = CreditCardConfig(statementDay: 18, dueOffsetDays: 25, limit: 500000)

        try await client.setCreditCardConfig(accountId: "acct_chase", config: config)

        // Read back from database
        let configs = try await database.fetchCreditCardConfigs()
        let stored = try #require(configs["acct_chase"])
        #expect(stored.statementDay == 18)
        #expect(stored.dueOffsetDays == 25)
        #expect(stored.limit == 500000)

        // Verify CRDT message in messages_crdt
        let messages = try messageRows(path: path)
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message["dataset"] == "preferences")
        #expect(message["row"] == "actuali:credit_card:acct_chase")
        #expect(message["column"] == "value")
    }

    @Test func clearingConfigSetsNullInPreferencesAndEmitsNullCRDTMessage() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        let client = try await makeSyncClient(database: database)
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
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        let client = try await makeSyncClient(database: database)

        try await client.setPreference(key: "actuali:custom:flag", value: "active")

        let prefs = try await database.fetchPreferences(prefix: "actuali:custom:")
        #expect(prefs["flag"] == "active")

        let messages = try messageRows(path: path)
        #expect(messages.count == 1)
        #expect(messages[0]["row"] == "actuali:custom:flag")
        #expect(messages[0]["value"] == "S:active")
    }
}
