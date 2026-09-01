import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetDatabaseGoalTemplateTests {

    /// Fixture mirrors a downloaded budget file that predates the goal
    /// migrations — no goal/long_goal/goal_def columns — so opening it also
    /// exercises the migration path.
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
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

                CREATE TABLE notes (
                    id TEXT PRIMARY KEY,
                    note TEXT
                );

                CREATE TABLE zero_budgets (
                    id TEXT PRIMARY KEY,
                    month INTEGER,
                    category TEXT,
                    amount INTEGER DEFAULT 0,
                    carryover INTEGER DEFAULT 0
                );

                INSERT INTO category_groups (id, name) VALUES ('grp-1', 'Daily');
                INSERT INTO category_groups (id, name, is_income) VALUES ('grp-inc', 'Income', 1);
                INSERT INTO categories (id, name, cat_group) VALUES ('cat-groceries', 'Groceries', 'grp-1');
                INSERT INTO categories (id, name, cat_group, is_income) VALUES ('cat-salary', 'Salary', 'grp-inc', 1);
                INSERT INTO category_mapping (id, transferId) VALUES
                    ('cat-groceries', 'cat-groceries'),
                    ('cat-salary', 'cat-salary');
                INSERT INTO accounts (id, name, offbudget, sort_order) VALUES ('acct-1', 'Checking', 0, 1.0);
            """)
        }
        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func migrationsAddGoalColumns() throws {
        let (_, path) = try makeDatabase()
        defer { cleanup(path) }

        let queue = try DatabaseQueue(path: path.path)
        try queue.read { db in
            let budgetColumns = Set(try db.columns(in: "zero_budgets").map(\.name))
            #expect(budgetColumns.contains("goal"))
            #expect(budgetColumns.contains("long_goal"))
            let categoryColumns = Set(try db.columns(in: "categories").map(\.name))
            #expect(categoryColumns.contains("goal_def"))
            #expect(categoryColumns.contains("template_settings"))
        }
    }

    @Test func fetchBudgetMonthSurfacesGoals() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO zero_budgets (id, month, category, amount, goal, long_goal)
                VALUES ('202401-cat-groceries', 202401, 'cat-groceries', 40000, 50000, 1)
                """)
        }

        let month = try await database.fetchBudgetMonth(month: "2024-01")
        let groceries = try #require(month.categoryBudgets.first { $0.categoryId == "cat-groceries" })
        #expect(groceries.goal == 50000)
        #expect(groceries.longGoal == true)
        #expect(groceries.differenceToGoal == groceries.available - 50000)
    }

    @Test func fetchGoalTemplateSheetBuildsSheetValues() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO zero_budgets (id, month, category, amount, carryover, goal)
                VALUES ('202312-cat-groceries', 202312, 'cat-groceries', 10000, 1, 7000);
                INSERT INTO transactions (id, acct, category, amount, date) VALUES
                    ('t-1', 'acct-1', 'cat-groceries', -4000, 20231215),
                    ('t-2', 'acct-1', 'cat-salary', 50000, 20231220);
                """)
        }

        let sheet = try await database.fetchGoalTemplateSheet(month: "2024-01")
        #expect(!sheet.isTracking)
        #expect(sheet.budgeted(month: "2023-12", category: "cat-groceries") == 10000)
        #expect(sheet.spent(month: "2023-12", category: "cat-groceries") == -4000)
        #expect(sheet.leftover(month: "2023-12", category: "cat-groceries") == 6000)
        #expect(sheet.carryover(month: "2023-12", category: "cat-groceries"))
        #expect(sheet.goal(month: "2023-12", category: "cat-groceries") == 7000)
        #expect(sheet.totalIncome(month: "2023-12") == 50000)
        #expect(sheet.firstActivityMonth["cat-groceries"] == 202312)
        // to-budget at 2024-01: December income (50000) minus budgeted (10000).
        #expect(sheet.availableStart == 40000)
    }

    @Test func fetchGoalTemplateCategoriesJoinsNotesAndSource() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO notes (id, note) VALUES ('cat-groceries', '#template 50');
                UPDATE categories SET template_settings = '{"source": "ui"}',
                    goal_def = '[{"type":"simple","directive":"template","priority":0,"monthly":75}]'
                    WHERE id = 'cat-salary'
                """)
        }

        let rows = try await database.fetchGoalTemplateCategories()
        let groceries = try #require(rows.first { $0.id == "cat-groceries" })
        #expect(groceries.note == "#template 50")
        #expect(!groceries.sourceIsUI)
        #expect(groceries.goalDef == nil)

        let salary = try #require(rows.first { $0.id == "cat-salary" })
        #expect(salary.sourceIsUI)
        #expect(salary.goalDef?.contains("simple") == true)
        #expect(salary.isIncome)
    }

    @Test func resetGoalDefsClearsColumn() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "UPDATE categories SET goal_def = '[]' WHERE id = 'cat-groceries'")
        }
        try await database.resetGoalDefs(categoryIds: ["cat-groceries"])

        let cleared = try await database.dbQueueForTesting.read { db in
            try String.fetchOne(db, sql: "SELECT goal_def FROM categories WHERE id = 'cat-groceries'")
        }
        #expect(cleared == nil)
    }
}
