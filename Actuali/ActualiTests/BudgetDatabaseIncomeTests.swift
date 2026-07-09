import Foundation
import Testing
import GRDB
@testable import Actuali

/// Income categories surfaced on BudgetMonth for the Budget tab's Income
/// section (mirrors the Income group in the Actual web UI's budget table).
@MainActor
struct BudgetDatabaseIncomeTests {

    private func makeDatabase(envelope: Bool = true) throws -> (BudgetDatabase, URL) {
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
                INSERT INTO categories (id, name, cat_group, is_income, sort_order) VALUES
                    ('cat-salary', 'Salary', 'grp-income', 1, 1.0),
                    ('cat-bonus', 'Bonus', 'grp-income', 1, 2.0);
                INSERT INTO category_mapping (id, transferId) VALUES
                    ('cat-salary', 'cat-salary'),
                    ('cat-bonus', 'cat-bonus');
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
        }
        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
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

    private func execSQL(_ db: BudgetDatabase, _ sql: String) throws {
        try db.dbQueueForTesting.write { conn in
            try conn.execute(sql: sql)
        }
    }

    @Test func incomeCategoriesListReceivedForTheMonth() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try insertTransaction(db, date: 20260601, category: "cat-salary", amount: 100_000)
        try insertTransaction(db, date: 20260615, category: "cat-salary", amount: 50_000)
        try insertTransaction(db, date: 20260620, category: "cat-bonus", amount: 25_000)
        // Different month: must not leak into June.
        try insertTransaction(db, date: 20260501, category: "cat-salary", amount: 999_000)
        // Expense activity must not appear as income.
        try insertTransaction(db, date: 20260610, category: "cat-groceries", amount: -30_000)

        let june = try await db.fetchBudgetMonth(month: "2026-06")

        #expect(june.incomeCategories.map(\.categoryId) == ["cat-salary", "cat-bonus"])
        #expect(june.incomeCategories.first?.received == 150_000)
        #expect(june.incomeCategories.last?.received == 25_000)
        #expect(june.totalIncome == 175_000)
        #expect(june.incomeCategories.first?.groupName == "Income")
        // Income categories stay out of the expense list.
        #expect(june.categoryBudgets.allSatisfy { $0.categoryId != "cat-salary" })
    }

    @Test func incomeCategoryWithNoActivityStillListedAtZero() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try insertTransaction(db, date: 20260601, category: "cat-salary", amount: 100_000)

        let june = try await db.fetchBudgetMonth(month: "2026-06")
        let bonus = june.incomeCategories.first { $0.categoryId == "cat-bonus" }
        #expect(bonus?.received == 0)
    }

    @Test func hiddenIncomeCategoryIsExcluded() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try execSQL(db, "UPDATE categories SET hidden = 1 WHERE id = 'cat-bonus'")
        try insertTransaction(db, date: 20260601, category: "cat-bonus", amount: 25_000)

        let june = try await db.fetchBudgetMonth(month: "2026-06")
        #expect(june.incomeCategories.map(\.categoryId) == ["cat-salary"])
    }

    @Test func trackingBudgetIncludesBudgetedIncome() async throws {
        let (db, url) = try makeDatabase(envelope: false)
        defer { cleanup(url) }

        try execSQL(db, """
            INSERT INTO reflect_budgets (id, month, category, amount)
            VALUES ('b-1', 202606, 'cat-salary', 120000)
            """)
        try insertTransaction(db, date: 20260601, category: "cat-salary", amount: 100_000)

        let june = try await db.fetchBudgetMonth(month: "2026-06")
        let salary = june.incomeCategories.first { $0.categoryId == "cat-salary" }
        #expect(salary?.budgeted == 120_000)
        #expect(salary?.received == 100_000)
    }
}
