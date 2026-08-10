import Foundation
import Testing
import GRDB
@testable import Actuali

struct BudgetDatabaseBudgetCellTests {

    private enum BudgetTable {
        case zero
        case reflect
        case none
    }

    private func makeDatabase(table: BudgetTable) throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            let tableName: String?
            switch table {
            case .zero: tableName = "zero_budgets"
            case .reflect: tableName = "reflect_budgets"
            case .none: tableName = nil
            }
            if let tableName {
                try db.execute(sql: """
                    CREATE TABLE \(tableName) (
                        id TEXT PRIMARY KEY,
                        month INTEGER,
                        category TEXT,
                        amount INTEGER DEFAULT 0,
                        carryover INTEGER DEFAULT 0
                    )
                    """)
            }
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func missingRowYieldsUpstreamIdFormat() throws {
        let (database, path) = try makeDatabase(table: .zero)
        defer { cleanup(path) }

        let cell = try #require(try database.budgetCell(month: "2026-07", categoryId: "cat-1"))
        #expect(cell.table == "zero_budgets")
        #expect(cell.rowId == "202607-cat-1")
        #expect(cell.monthInt == 202607)
        #expect(cell.exists == false)
        // No row yet means nothing budgeted — transfers start from zero.
        #expect(cell.amount == 0)
    }

    /// Upstream setBudget looks the row up by (month, category) and reuses its
    /// id — rows written by other clients may not follow the {month}-{category}
    /// id convention, and writing a second row for the same cell would fork it.
    @Test func existingRowKeepsItsOwnId() throws {
        let (database, path) = try makeDatabase(table: .zero)
        defer { cleanup(path) }
        try database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO zero_budgets (id, month, category, amount) VALUES ('legacy-id', 202607, 'cat-1', 500)
                """)
        }

        let cell = try #require(try database.budgetCell(month: "2026-07", categoryId: "cat-1"))
        #expect(cell.rowId == "legacy-id")
        #expect(cell.exists == true)
        // The current budgeted amount rides along so transfer writes can
        // compute source-minus / destination-plus without a second read.
        #expect(cell.amount == 500)
    }

    @Test func trackingBudgetUsesReflectTable() throws {
        let (database, path) = try makeDatabase(table: .reflect)
        defer { cleanup(path) }

        let cell = try #require(try database.budgetCell(month: "2026-07", categoryId: "cat-1"))
        #expect(cell.table == "reflect_budgets")
        #expect(cell.rowId == "202607-cat-1")
    }

    @Test func noBudgetTablesYieldsNil() throws {
        let (database, path) = try makeDatabase(table: .none)
        defer { cleanup(path) }

        #expect(try database.budgetCell(month: "2026-07", categoryId: "cat-1") == nil)
    }

    @Test func malformedMonthYieldsNil() throws {
        let (database, path) = try makeDatabase(table: .zero)
        defer { cleanup(path) }

        #expect(try database.budgetCell(month: "garbage", categoryId: "cat-1") == nil)
    }
}
