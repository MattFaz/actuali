import Foundation
import GRDB
import Testing
@testable import Actuali

struct SyncClientSetBudgetAmountTests {

    /// The budget table and messages_crdt normally come from the downloaded
    /// budget file, so create them with the upstream schema.
    private func makeDatabase(budgetTable: String? = "zero_budgets") throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            if let budgetTable {
                try db.execute(sql: """
                    CREATE TABLE \(budgetTable) (
                        id TEXT PRIMARY KEY,
                        month INTEGER,
                        category TEXT,
                        amount INTEGER DEFAULT 0,
                        carryover INTEGER DEFAULT 0
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

    private func budgetRows(path: URL, table: String = "zero_budgets") throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY id")
        }
    }

    private func messageRows(path: URL) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messages_crdt ORDER BY timestamp")
        }
    }

    @Test func newCellInsertsRowAndEmitsFullInsertMessages() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.setBudgetAmount(month: "2026-07", categoryId: "cat-1", amount: 12345)

        let rows = try budgetRows(path: path)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["id"] == "202607-cat-1")
        #expect(row["month"] == 202607)
        #expect(row["category"] == "cat-1")
        #expect(row["amount"] == 12345)

        // Upstream's insert writes month, category and amount, so all three
        // must be replicated for other clients to materialize the same row.
        let messages = try messageRows(path: path)
        #expect(messages.count == 3)
        for message in messages {
            #expect(message["dataset"] == "zero_budgets")
            #expect(message["row"] == "202607-cat-1")
        }
        let byColumn = Dictionary(uniqueKeysWithValues: messages.map { ($0["column"] as String? ?? "", $0["value"] as String? ?? "") })
        #expect(byColumn["amount"] == "N:12345")
        #expect(byColumn["month"] == "N:202607")
        #expect(byColumn["category"] == "S:cat-1")
    }

    @Test func existingCellUpdatesInPlaceAndEmitsAmountOnly() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO zero_budgets (id, month, category, amount) VALUES ('legacy-id', 202607, 'cat-1', 500)
                """)
        }
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.setBudgetAmount(month: "2026-07", categoryId: "cat-1", amount: 700)

        let rows = try budgetRows(path: path)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["id"] == "legacy-id")
        #expect(row["amount"] == 700)

        let messages = try messageRows(path: path)
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message["dataset"] == "zero_budgets")
        #expect(message["row"] == "legacy-id")
        #expect(message["column"] == "amount")
        #expect(message["value"] == "N:700")
    }

    @Test func trackingBudgetWritesReflectTable() async throws {
        let (database, path) = try makeDatabase(budgetTable: "reflect_budgets")
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.setBudgetAmount(month: "2026-07", categoryId: "cat-1", amount: 2000)

        let rows = try budgetRows(path: path, table: "reflect_budgets")
        #expect(rows.count == 1)
        #expect(try #require(rows.first)["amount"] == 2000)

        let messages = try messageRows(path: path)
        #expect(messages.allSatisfy { $0["dataset"] == "reflect_budgets" })
    }

    @Test func missingBudgetTableThrowsWithoutEmittingMessages() async throws {
        let (database, path) = try makeDatabase(budgetTable: nil)
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        await #expect(throws: SyncError.self) {
            try await syncClient.setBudgetAmount(month: "2026-07", categoryId: "cat-1", amount: 100)
        }
        #expect(try messageRows(path: path).isEmpty)
    }
}
