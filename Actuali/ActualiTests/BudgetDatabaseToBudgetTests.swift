import Foundation
import Testing
import GRDB
@testable import Actuali

/// Envelope "To Budget" (unallocated funds), mirroring loot-core envelope.ts:
///   to-budget = income + prior to-budget + prior buffered
///               + last-month-overspent - budgeted - buffered
@MainActor
struct BudgetDatabaseToBudgetTests {

    private func makeDatabase(
        envelope: Bool = true,
        withBufferTable: Bool = true
    ) throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")

        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    acct TEXT,
                    category TEXT,
                    description TEXT,
                    amount INTEGER,
                    date INTEGER,
                    transferred_id TEXT,
                    parent_id TEXT,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    is_income INTEGER DEFAULT 0,
                    cat_group TEXT,
                    sort_order REAL,
                    hidden INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE category_groups (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    is_income INTEGER DEFAULT 0,
                    sort_order REAL,
                    hidden INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
                );

                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    offbudget INTEGER DEFAULT 0,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0
                );

                INSERT INTO category_groups (id, name) VALUES ('grp-1', 'Daily');
                INSERT INTO categories (id, name, cat_group) VALUES ('cat-groceries', 'Groceries', 'grp-1');
                INSERT INTO category_mapping (id, transferId) VALUES ('cat-groceries', 'cat-groceries');
                INSERT INTO category_groups (id, name, is_income) VALUES ('grp-income', 'Income', 1);
                INSERT INTO categories (id, name, cat_group, is_income) VALUES ('cat-salary', 'Salary', 'grp-income', 1);
                INSERT INTO category_mapping (id, transferId) VALUES ('cat-salary', 'cat-salary');
                INSERT INTO accounts (id, name, offbudget, sort_order) VALUES
                    ('acct-1', 'Checking', 0, 1.0);
            """)

            let table = envelope ? "zero_budgets" : "reflect_budgets"
            try db.execute(sql: """
                CREATE TABLE \(table) (
                    id TEXT PRIMARY KEY,
                    month INTEGER,
                    category TEXT,
                    amount INTEGER DEFAULT 0,
                    carryover INTEGER DEFAULT 0
                );
            """)

            if withBufferTable {
                try db.execute(sql: """
                    CREATE TABLE zero_budget_months (
                        id TEXT PRIMARY KEY,
                        buffered INTEGER DEFAULT 0
                    );
                """)
            }
        }
        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func insertBudget(
        _ db: BudgetDatabase,
        table: String = "zero_budgets",
        month: Int,
        category: String,
        amount: Int,
        carryover: Bool = false
    ) throws {
        try db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO \(table) (id, month, category, amount, carryover) VALUES (?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, month, category, amount, carryover ? 1 : 0])
        }
    }

    private func insertTransaction(
        _ db: BudgetDatabase,
        date: Int,
        category: String?,
        amount: Int
    ) throws {
        try db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, category, amount, date, tombstone)
                VALUES (?, 'acct-1', ?, ?, ?, 0)
                """, arguments: [UUID().uuidString, category, amount, date])
        }
    }

    private func insertBuffer(_ db: BudgetDatabase, month: String, amount: Int) throws {
        try db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO zero_budget_months (id, buffered) VALUES (?, ?)
                """, arguments: [month, amount])
        }
    }

    private func insertHiddenCategory(_ db: BudgetDatabase, id: String) throws {
        try db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO categories (id, name, cat_group, hidden) VALUES (?, 'Hidden', 'grp-1', 1)
                """, arguments: [id])
            try conn.execute(sql: """
                INSERT INTO category_mapping (id, transferId) VALUES (?, ?)
                """, arguments: [id, id])
        }
    }

    @Test func incomeMinusBudgeted() async throws {
        // June: salary +1000.00, groceries budgeted 300.00.
        // To Budget = 100000 - 30000 = 70000.
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try insertTransaction(db, date: 20260601, category: "cat-salary", amount: 100_000)
        try insertBudget(db, month: 202606, category: "cat-groceries", amount: 30_000)

        let june = try await db.fetchBudgetMonth(month: "2026-06")
        #expect(june.toBudget == 70_000)
    }

    @Test func unbudgetedIncomeAccumulatesAcrossMonths() async throws {
        // May: income 500.00, budgeted 200.00 -> To Budget 300.00.
        // June: no income, budgeted 100.00 -> To Budget 300.00 - 100.00 = 200.00.
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try insertTransaction(db, date: 20260501, category: "cat-salary", amount: 50_000)
        try insertBudget(db, month: 202605, category: "cat-groceries", amount: 20_000)
        try insertBudget(db, month: 202606, category: "cat-groceries", amount: 10_000)

        let may = try await db.fetchBudgetMonth(month: "2026-05")
        #expect(may.toBudget == 30_000)

        let june = try await db.fetchBudgetMonth(month: "2026-06")
        #expect(june.toBudget == 20_000)
    }

    @Test func overspendingReducesNextMonthToBudget() async throws {
        // May: income 500.00, budgeted 200.00, spent 300.00 (overspent 100.00).
        // The clamped -100.00 comes out of June's To Budget:
        // June = (500 - 200) - 100 = 200.00.
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try insertTransaction(db, date: 20260501, category: "cat-salary", amount: 50_000)
        try insertBudget(db, month: 202605, category: "cat-groceries", amount: 20_000)
        try insertTransaction(db, date: 20260510, category: "cat-groceries", amount: -30_000)

        let may = try await db.fetchBudgetMonth(month: "2026-05")
        #expect(may.toBudget == 30_000)

        let june = try await db.fetchBudgetMonth(month: "2026-06")
        #expect(june.toBudget == 20_000)
    }

    @Test func overspendingWithCarryoverFlagStaysInCategory() async throws {
        // Same as above but the carryover flag is ON for May: the -100.00
        // debt stays on the category, so June's To Budget is untouched.
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try insertTransaction(db, date: 20260501, category: "cat-salary", amount: 50_000)
        try insertBudget(db, month: 202605, category: "cat-groceries", amount: 20_000, carryover: true)
        try insertTransaction(db, date: 20260510, category: "cat-groceries", amount: -30_000)

        let june = try await db.fetchBudgetMonth(month: "2026-06")
        #expect(june.toBudget == 30_000)
    }

    @Test func bufferedHoldSubtractsAndCarriesForward() async throws {
        // May: income 500.00, hold 200.00 for next month -> To Budget 300.00.
        // June: from-last-month = 300.00 + 200.00 held -> To Budget 500.00.
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try insertTransaction(db, date: 20260501, category: "cat-salary", amount: 50_000)
        try insertBuffer(db, month: "2026-05", amount: 20_000)

        let may = try await db.fetchBudgetMonth(month: "2026-05")
        #expect(may.toBudget == 30_000)

        let june = try await db.fetchBudgetMonth(month: "2026-06")
        #expect(june.toBudget == 50_000)
    }

    @Test func hiddenCategoryBudgetStillCounts() async throws {
        // Hidden categories are filtered from the display list but their
        // budgeted money is still allocated (upstream includes them).
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try insertHiddenCategory(db, id: "cat-hidden")
        try insertTransaction(db, date: 20260601, category: "cat-salary", amount: 50_000)
        try insertBudget(db, month: 202606, category: "cat-hidden", amount: 10_000)

        let june = try await db.fetchBudgetMonth(month: "2026-06")
        #expect(june.categoryBudgets.first { $0.categoryId == "cat-hidden" } == nil)
        #expect(june.toBudget == 40_000)
    }

    @Test func trackingBudgetHasNoToBudget() async throws {
        // Tracking (reflect) budgets have no unallocated-funds concept.
        let (db, url) = try makeDatabase(envelope: false, withBufferTable: false)
        defer { cleanup(url) }

        try insertTransaction(db, date: 20260601, category: "cat-salary", amount: 50_000)
        try insertBudget(db, table: "reflect_budgets", month: 202606, category: "cat-groceries", amount: 10_000)

        let june = try await db.fetchBudgetMonth(month: "2026-06")
        #expect(june.toBudget == nil)
    }

    @Test func missingBufferTableIsTolerated() async throws {
        // Older/partial files may lack zero_budget_months entirely.
        let (db, url) = try makeDatabase(withBufferTable: false)
        defer { cleanup(url) }

        try insertTransaction(db, date: 20260601, category: "cat-salary", amount: 50_000)
        try insertBudget(db, month: 202606, category: "cat-groceries", amount: 10_000)

        let june = try await db.fetchBudgetMonth(month: "2026-06")
        #expect(june.toBudget == 40_000)
    }
}
