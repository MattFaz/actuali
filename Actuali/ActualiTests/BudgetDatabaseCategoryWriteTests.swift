import Foundation
import Testing
import GRDB
@testable import Actuali

/// Creating category groups and categories from the app (GH #284). Mirrors
/// upstream `insertCategoryGroup` / `insertCategory`
/// (packages/loot-core/src/server/db/index.ts): groups append, categories go
/// to the top of their group, and both refuse duplicate names.
@MainActor
struct BudgetDatabaseCategoryWriteTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")

        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
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

                INSERT INTO category_groups (id, name, sort_order) VALUES
                    ('grp-daily', 'Daily', 16384.0),
                    ('grp-bills', 'Bills', 32768.0);
                INSERT INTO category_groups (id, name, is_income, sort_order)
                    VALUES ('grp-income', 'Income', 1, 49152.0);
                INSERT INTO categories (id, name, cat_group, sort_order) VALUES
                    ('cat-groceries', 'Groceries', 'grp-daily', 16384.0),
                    ('cat-fuel', 'Fuel', 'grp-daily', 32768.0);
                INSERT INTO category_mapping (id, transferId) VALUES
                    ('cat-groceries', 'cat-groceries'),
                    ('cat-fuel', 'cat-fuel');
            """)
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Groups

    @Test func newGroupSortsAfterEveryExistingOne() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        let group = try db.insertCategoryGroup(id: "grp-fun", name: "Fun Money")

        #expect(group.sortOrder == 49152 + SortOrder.increment)
        #expect(!group.isIncome)
        #expect(!group.hidden)
        #expect(group.categories.isEmpty)

        let groups = try await db.fetchCategoryGroups()
        #expect(groups.map(\.name) == ["Daily", "Bills", "Income", "Fun Money"])
    }

    @Test func groupNamesAreUniqueRegardlessOfCase() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        #expect(throws: BudgetDatabase.CategoryWriteError.duplicateGroupName("Bills")) {
            try db.insertCategoryGroup(id: "grp-dupe", name: "bills")
        }

        // The rejected group left nothing behind.
        let groups = try await db.fetchCategoryGroups()
        #expect(groups.count == 3)
    }

    @Test func aTombstonedGroupDoesNotBlockItsName() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: "UPDATE category_groups SET tombstone = 1 WHERE id = 'grp-bills'")
        }

        let group = try db.insertCategoryGroup(id: "grp-bills-2", name: "Bills")
        #expect(group.id == "grp-bills-2")
    }

    // MARK: - Categories

    @Test func newCategoryLandsAtTheTopOfItsGroup() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        let insertion = try db.insertCategory(id: "cat-coffee", name: "Coffee", groupId: "grp-daily")

        // Midpoint below the group's first category, no siblings displaced.
        #expect(insertion.category.sortOrder == 8192)
        #expect(insertion.movedSiblings.isEmpty)

        let daily = try await db.fetchCategoryGroups().first { $0.id == "grp-daily" }
        #expect(daily?.categories.map(\.name) == ["Coffee", "Groceries", "Fuel"])
    }

    @Test func newCategoryTakesItsGroupsIncomeAndHiddenFlags() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: "UPDATE category_groups SET hidden = 1 WHERE id = 'grp-income'")
        }

        let insertion = try db.insertCategory(id: "cat-salary", name: "Salary", groupId: "grp-income")

        #expect(insertion.category.isIncome)
        #expect(insertion.category.hidden)
        // First category in the group, so it appends rather than shoving.
        #expect(insertion.category.sortOrder == SortOrder.increment)
    }

    @Test func newCategoryGetsItsSelfMappingRow() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        _ = try db.insertCategory(id: "cat-coffee", name: "Coffee", groupId: "grp-daily")

        let target = try await db.dbQueueForTesting.read { conn in
            try String.fetchOne(
                conn,
                sql: "SELECT transferId FROM category_mapping WHERE id = ?",
                arguments: ["cat-coffee"])
        }
        #expect(target == "cat-coffee")
    }

    @Test func aCrowdedGroupShovesItsCategoriesToMakeRoom() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: "UPDATE categories SET sort_order = 2.0 WHERE id = 'cat-groceries'")
        }

        let insertion = try db.insertCategory(id: "cat-coffee", name: "Coffee", groupId: "grp-daily")

        #expect(insertion.movedSiblings == [
            SortOrder.Position(id: "cat-groceries", sortOrder: 16386),
            SortOrder.Position(id: "cat-fuel", sortOrder: 32770)
        ])
        #expect(insertion.category.sortOrder == 1)

        // The shove is written, not just reported.
        let daily = try await db.fetchCategoryGroups().first { $0.id == "grp-daily" }
        #expect(daily?.categories.map(\.name) == ["Coffee", "Groceries", "Fuel"])
    }

    @Test func categoryNamesAreUniqueWithinTheirGroup() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        #expect(throws: BudgetDatabase.CategoryWriteError.duplicateCategoryName(
            name: "groceries",
            groupName: "Daily"
        )) {
            try db.insertCategory(id: "cat-dupe", name: "groceries", groupId: "grp-daily")
        }
    }

    @Test func theSameNameIsFineInAnotherGroup() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        let insertion = try db.insertCategory(id: "cat-groceries-2", name: "Groceries", groupId: "grp-bills")
        #expect(insertion.category.groupId == "grp-bills")
    }

    @Test func anUnknownGroupIsRefused() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        #expect(throws: BudgetDatabase.CategoryWriteError.groupNotFound) {
            try db.insertCategory(id: "cat-orphan", name: "Orphan", groupId: "grp-gone")
        }
    }
}
