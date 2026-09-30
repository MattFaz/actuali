import Foundation
import GRDB
import Testing
@testable import Actuali

struct SyncClientSetBudgetAmountTests {
    /// The budget table and messages_crdt normally come from the downloaded
    /// budget file, so create them with the upstream schema.
    private func makeDatabase(budgetTable: String? = TestSchema.zeroBudgets) async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase([budgetTable, TestSchema.messagesCrdt].compactMap(\.self))
    }

    // Sync client wired to a real database. The server client is
    // unconfigured, so the post-write automatic sync fails fast and locally
    // without touching the network.

    private func budgetRows(path: URL, table: String = "zero_budgets") throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY id")
        }
    }

    @Test func envelopeBufferCreatesMissingTableRowAndPersistsCRDTMessage() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeTestSyncClient(database: database)

        try await syncClient.setBudgetBuffer(month: "2026-07", amount: 2500)

        let queue = try DatabaseQueue(path: path.path)
        let buffered = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT buffered FROM zero_budget_months WHERE id = ?",
                arguments: ["2026-07"]
            )
        }
        #expect(buffered == 2500)

        let messages = try messageRows(path: path)
        let message = try #require(messages.first)
        #expect(message["dataset"] == "zero_budget_months")
        #expect(message["row"] == "2026-07")
        #expect(message["column"] == "buffered")
        #expect(message["value"] == "N:2500")
    }

    @Test func newCellInsertsRowAndEmitsFullInsertMessages() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeTestSyncClient(database: database)

        try await syncClient.setBudgetAmount(month: "2026-07", categoryId: "cat-1", amount: 12345)

        let rows = try budgetRows(path: path)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["id"] == "202607-cat-1")
        #expect(row["month"] == 202_607)
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
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
            INSERT INTO zero_budgets (id, month, category, amount) VALUES ('legacy-id', 202607, 'cat-1', 500)
            """)
        }
        let syncClient = try await makeTestSyncClient(database: database)

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
        let (database, path) = try await makeDatabase(budgetTable: TestSchema.reflectBudgets)
        defer { cleanup(path) }
        let syncClient = try await makeTestSyncClient(database: database)

        try await syncClient.setBudgetAmount(month: "2026-07", categoryId: "cat-1", amount: 2000)

        let rows = try budgetRows(path: path, table: "reflect_budgets")
        #expect(rows.count == 1)
        #expect(try #require(rows.first)["amount"] == 2000)

        let messages = try messageRows(path: path)
        #expect(messages.allSatisfy { $0["dataset"] == "reflect_budgets" })
    }

    @Test func missingBudgetTableThrowsWithoutEmittingMessages() async throws {
        let (database, path) = try await makeDatabase(budgetTable: nil)
        defer { cleanup(path) }
        let syncClient = try await makeTestSyncClient(database: database)

        await #expect(throws: SyncError.self) {
            try await syncClient.setBudgetAmount(month: "2026-07", categoryId: "cat-1", amount: 100)
        }
        #expect(try messageRows(path: path).isEmpty)
    }
}
