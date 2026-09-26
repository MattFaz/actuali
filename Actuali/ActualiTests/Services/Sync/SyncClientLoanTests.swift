import Foundation
import GRDB
import Testing
@testable import Actuali

/// Pins `setLoanConfig()` on `SyncClient`: the config lands in the local
/// `preferences` table and emits a CRDT message on dataset "preferences",
/// row "actuali:loan:<accountId>", column "value", so it converges like any
/// other synced preference.
@MainActor
struct SyncClientLoanTests {
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
        return try (BudgetDatabase(path: tempURL), tempURL)
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

    private let config = LoanConfig(
        originalBalance: 2_200_000,
        annualRatePercent: 6,
        minimumPayment: 36500,
        escrowOrFees: 20000
    )

    @Test func writesPreferencesRowAndEmitsCRDTMessage() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        let client = try await makeSyncClient(database: database)
        try await client.setLoanConfig(accountId: "acct_car", config: config)

        let configs = try await database.fetchLoanConfigs()
        let stored = try #require(configs["acct_car"])
        #expect(stored == config)

        let messages = try messageRows(path: path)
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message["dataset"] == "preferences")
        #expect(message["row"] == "actuali:loan:acct_car")
        #expect(message["column"] == "value")
    }

    @Test func clearingConfigSetsNullInPreferencesAndEmitsNullCRDTMessage() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        let client = try await makeSyncClient(database: database)
        try await client.setLoanConfig(accountId: "acct_car", config: config)
        try await client.setLoanConfig(accountId: "acct_car", config: nil)

        let configs = try await database.fetchLoanConfigs()
        #expect(configs["acct_car"] == nil)

        let messages = try messageRows(path: path)
        #expect(messages.count == 2)
        #expect(messages[1]["row"] == "actuali:loan:acct_car")
        #expect(messages[1]["value"] == "0:") // Null CRDT value representation
    }
}
