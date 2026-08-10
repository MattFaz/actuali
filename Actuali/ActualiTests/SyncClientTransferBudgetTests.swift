import Foundation
import GRDB
import Testing
@testable import Actuali

struct SyncClientTransferBudgetTests {

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

    private func seedCell(_ database: BudgetDatabase, id: String, month: Int, category: String, amount: Int) throws {
        try database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO zero_budgets (id, month, category, amount) VALUES (?, ?, ?, ?)
                """, arguments: [id, month, category, amount])
        }
    }

    private func budgetAmounts(path: URL) throws -> [String: Int] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            var amounts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT category, amount FROM zero_budgets") {
                amounts[row["category"]] = row["amount"]
            }
            return amounts
        }
    }

    private func messageRows(path: URL) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messages_crdt ORDER BY timestamp")
        }
    }

    @Test func transferBetweenCategoriesMovesBudgetedAmount() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        try seedCell(database, id: "202607-cat-1", month: 202607, category: "cat-1", amount: 5000)
        try seedCell(database, id: "202607-cat-2", month: 202607, category: "cat-2", amount: 1000)
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.transferBudget(month: "2026-07", fromCategoryId: "cat-1", toCategoryId: "cat-2", amount: 2000)

        let amounts = try budgetAmounts(path: path)
        #expect(amounts["cat-1"] == 3000)
        #expect(amounts["cat-2"] == 3000)

        // Both cells exist, so exactly one amount message per cell — the same
        // shape upstream transferCategory replicates.
        let messages = try messageRows(path: path)
        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0["dataset"] == "zero_budgets" })
        #expect(messages.allSatisfy { $0["column"] == "amount" })
        let byRow = Dictionary(uniqueKeysWithValues: messages.map { ($0["row"] as String? ?? "", $0["value"] as String? ?? "") })
        #expect(byRow["202607-cat-1"] == "N:3000")
        #expect(byRow["202607-cat-2"] == "N:3000")
    }

    /// Covering from "To Budget": the unallocated figure is derived, so only
    /// the destination cell is written (upstream coverOverspending's
    /// to-be-budgeted branch).
    @Test func coverFromToBudgetWritesOnlyDestination() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        try seedCell(database, id: "202607-cat-1", month: 202607, category: "cat-1", amount: 500)
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.transferBudget(month: "2026-07", fromCategoryId: nil, toCategoryId: "cat-1", amount: 3000)

        let amounts = try budgetAmounts(path: path)
        #expect(amounts == ["cat-1": 3500])

        let messages = try messageRows(path: path)
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message["row"] == "202607-cat-1")
        #expect(message["column"] == "amount")
        #expect(message["value"] == "N:3500")
    }

    /// Moving a category's funds back to "To Budget": only the source cell
    /// shrinks (upstream transferAvailable).
    @Test func transferToToBudgetWritesOnlySource() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        try seedCell(database, id: "202607-cat-1", month: 202607, category: "cat-1", amount: 5000)
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.transferBudget(month: "2026-07", fromCategoryId: "cat-1", toCategoryId: nil, amount: 2000)

        let amounts = try budgetAmounts(path: path)
        #expect(amounts == ["cat-1": 3000])

        let messages = try messageRows(path: path)
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message["row"] == "202607-cat-1")
        #expect(message["value"] == "N:3000")
    }

    /// A destination that was never budgeted has no row yet: it must be
    /// created with the full month/category/amount insert, like setBudgetAmount.
    @Test func missingDestinationRowIsCreatedWithFullInsertMessages() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        try seedCell(database, id: "202607-cat-1", month: 202607, category: "cat-1", amount: 5000)
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.transferBudget(month: "2026-07", fromCategoryId: "cat-1", toCategoryId: "cat-new", amount: 1500)

        let amounts = try budgetAmounts(path: path)
        #expect(amounts["cat-1"] == 3500)
        #expect(amounts["cat-new"] == 1500)

        let messages = try messageRows(path: path)
        let newCellMessages = messages.filter { $0["row"] == "202607-cat-new" }
        let byColumn = Dictionary(uniqueKeysWithValues: newCellMessages.map { ($0["column"] as String? ?? "", $0["value"] as String? ?? "") })
        #expect(byColumn["amount"] == "N:1500")
        #expect(byColumn["month"] == "N:202607")
        #expect(byColumn["category"] == "S:cat-new")
    }

    @Test func missingBudgetTableThrowsWithoutEmittingMessages() async throws {
        let (database, path) = try makeDatabase(budgetTable: nil)
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        await #expect(throws: SyncError.self) {
            try await syncClient.transferBudget(month: "2026-07", fromCategoryId: "cat-1", toCategoryId: "cat-2", amount: 100)
        }
        #expect(try messageRows(path: path).isEmpty)
    }
}
