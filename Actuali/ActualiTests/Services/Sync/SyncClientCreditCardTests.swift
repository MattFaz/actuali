import Foundation
import GRDB
import Testing
@testable import Actuali

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
                )
                """)
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

    private func makeSyncClient(database: BudgetDatabase) async throws -> SyncClient {
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        return syncClient
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func writesPreferencesRowAndEmitsCRDTMessage() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        let client = try await makeSyncClient(database: database)
        let config = CreditCardConfig(statementDay: 18, dueOffsetDays: 25, limit: 500000)

        try await client.setCreditCardConfig(accountId: "acct_chase", config: config)

        let configs = try await database.fetchCreditCardConfigs()
        #expect(configs["acct_chase"]?.statementDay == 18)
        #expect(configs["acct_chase"]?.dueOffsetDays == 25)
        #expect(configs["acct_chase"]?.limit == 500000)

        // Verify CRDT message in messages_crdt
        let queue = try DatabaseQueue(path: path.path)
        let messages = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messages_crdt WHERE dataset = 'preferences'")
        }
        #expect(messages.count == 1)
        #expect(messages[0]["row"] == "actuali:credit_card:acct_chase")
        #expect(messages[0]["column"] == "value")
    }

    @Test func clearingConfigSetsNullInPreferences() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        let client = try await makeSyncClient(database: database)
        let config = CreditCardConfig(statementDay: 18, dueOffsetDays: 25)

        try await client.setCreditCardConfig(accountId: "acct_chase", config: config)
        try await client.setCreditCardConfig(accountId: "acct_chase", config: nil)

        let configs = try await database.fetchCreditCardConfigs()
        #expect(configs["acct_chase"] == nil)
    }

    @Test func genericSetPreferenceWritesRow() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        let client = try await makeSyncClient(database: database)

        try await client.setPreference(key: "actuali:custom:flag", value: "active")

        let prefs = try await database.fetchPreferences(prefix: "actuali:custom:")
        #expect(prefs["flag"] == "active")
    }
}
