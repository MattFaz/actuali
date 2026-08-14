import Foundation
import Testing
import GRDB
@testable import Actuali

struct BudgetDatabaseBudgetCellTests {

    private enum BudgetTable {
        case zero
        case reflect
        case both
        case none
    }

    private func makeDatabase(
        table: BudgetTable,
        budgetTypePref: String? = nil
    ) throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            let tableNames: [String]
            switch table {
            case .zero: tableNames = ["zero_budgets"]
            case .reflect: tableNames = ["reflect_budgets"]
            case .both: tableNames = ["zero_budgets", "reflect_budgets"]
            case .none: tableNames = []
            }
            for tableName in tableNames {
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
            if let budgetTypePref {
                try db.execute(sql: "CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT)")
                try db.execute(
                    sql: "INSERT INTO preferences (id, value) VALUES ('budgetType', ?)",
                    arguments: [budgetTypePref]
                )
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

    /// Real Actual files always contain BOTH budget tables (loot-core's
    /// migrations create them unconditionally); the budgetType preference is
    /// the only thing that says which one the file actually uses. Issue #98:
    /// picking by table existence always chose zero_budgets, so tracking
    /// budgets read and wrote the wrong table.
    @Test func bothTablesWithTrackingPrefUsesReflectTable() throws {
        let (database, path) = try makeDatabase(table: .both, budgetTypePref: "tracking")
        defer { cleanup(path) }

        let cell = try #require(try database.budgetCell(month: "2026-07", categoryId: "cat-1"))
        #expect(cell.table == "reflect_budgets")
    }

    /// Files last written by Actual < 25.5 store the pre-rename value
    /// ("report" instead of "tracking").
    @Test func bothTablesWithLegacyReportPrefUsesReflectTable() throws {
        let (database, path) = try makeDatabase(table: .both, budgetTypePref: "report")
        defer { cleanup(path) }

        let cell = try #require(try database.budgetCell(month: "2026-07", categoryId: "cat-1"))
        #expect(cell.table == "reflect_budgets")
    }

    @Test func bothTablesWithEnvelopePrefUsesZeroTable() throws {
        let (database, path) = try makeDatabase(table: .both, budgetTypePref: "envelope")
        defer { cleanup(path) }

        let cell = try #require(try database.budgetCell(month: "2026-07", categoryId: "cat-1"))
        #expect(cell.table == "zero_budgets")
    }

    /// No budgetType preference row means envelope (upstream's default).
    @Test func bothTablesWithoutPrefDefaultsToZeroTable() throws {
        let (database, path) = try makeDatabase(table: .both)
        defer { cleanup(path) }

        let cell = try #require(try database.budgetCell(month: "2026-07", categoryId: "cat-1"))
        #expect(cell.table == "zero_budgets")
    }

    /// A tracking pref can't override a missing table — fall back to what
    /// actually exists rather than writing into a table that isn't there.
    @Test func trackingPrefWithOnlyZeroTableFallsBackToZeroTable() throws {
        let (database, path) = try makeDatabase(table: .zero, budgetTypePref: "tracking")
        defer { cleanup(path) }

        let cell = try #require(try database.budgetCell(month: "2026-07", categoryId: "cat-1"))
        #expect(cell.table == "zero_budgets")
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
