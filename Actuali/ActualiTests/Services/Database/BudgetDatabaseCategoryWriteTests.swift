import Foundation
import GRDB
import Testing
@testable import Actuali

/// Creating category groups and categories from the app (GH #284). Mirrors
/// upstream `insertCategoryGroup` / `insertCategory`
/// (packages/loot-core/src/server/db/index.ts): groups append, categories go
/// to the top of their group, and both refuse duplicate names.
@MainActor
struct BudgetDatabaseCategoryWriteTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(
            TestSchema.categories, TestSchema.categoryGroups, TestSchema.categoryMapping,
            """
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
            """
        )
    }

    // MARK: - Groups

    @Test func newGroupSortsAfterEveryExistingOne() async throws {
        let (db, url) = try await makeDatabase()
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
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        #expect(throws: BudgetDatabase.CategoryWriteError.duplicateGroupName("Bills")) {
            try db.insertCategoryGroup(id: "grp-dupe", name: "bills")
        }

        // The rejected group left nothing behind.
        let groups = try await db.fetchCategoryGroups()
        #expect(groups.count == 3)
    }

    @Test func groupNamesUseUnicodeCaseFolding() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }
        _ = try db.insertCategoryGroup(id: "grp-savings", name: "Épargne")

        #expect(throws: BudgetDatabase.CategoryWriteError.duplicateGroupName("Épargne")) {
            try db.insertCategoryGroup(id: "grp-dupe", name: "épargne")
        }
    }

    @Test func unnamedCRDTRowsDoNotBlockCategoryWrites() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: "INSERT INTO category_groups (id) VALUES ('grp-partial')")
            try conn.execute(sql: """
            INSERT INTO categories (id, cat_group) VALUES ('cat-partial', 'grp-daily')
            """)
        }

        _ = try db.insertCategoryGroup(id: "grp-fun", name: "Fun")
        _ = try db.insertCategory(id: "cat-coffee", name: "Coffee", groupId: "grp-daily")
        try db.validateCategoryGroupRename(id: "grp-bills", name: "Fixed Costs")
        try db.validateCategoryRename(id: "cat-fuel", name: "Transport")
    }

    @Test func aTombstonedGroupDoesNotBlockItsName() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: "UPDATE category_groups SET tombstone = 1 WHERE id = 'grp-bills'")
        }

        let group = try db.insertCategoryGroup(id: "grp-bills-2", name: "Bills")
        #expect(group.id == "grp-bills-2")
    }

    // MARK: - Categories

    @Test func newCategoryLandsAtTheTopOfItsGroup() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        let insertion = try db.insertCategory(id: "cat-coffee", name: "Coffee", groupId: "grp-daily")

        // Midpoint below the group's first category, no siblings displaced.
        #expect(insertion.category.sortOrder == 8192)
        #expect(insertion.movedSiblings.isEmpty)

        let daily = try await db.fetchCategoryGroups().first { $0.id == "grp-daily" }
        #expect(daily?.categories.map(\.name) == ["Coffee", "Groceries", "Fuel"])
    }

    @Test func newCategoryTakesItsGroupsIncomeAndHiddenFlags() async throws {
        let (db, url) = try await makeDatabase()
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
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        _ = try db.insertCategory(id: "cat-coffee", name: "Coffee", groupId: "grp-daily")

        let target = try await db.dbQueueForTesting.read { conn in
            try String.fetchOne(
                conn,
                sql: "SELECT transferId FROM category_mapping WHERE id = ?",
                arguments: ["cat-coffee"]
            )
        }
        #expect(target == "cat-coffee")
    }

    @Test func aCrowdedGroupShovesItsCategoriesToMakeRoom() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: "UPDATE categories SET sort_order = 2.0 WHERE id = 'cat-groceries'")
        }

        let insertion = try db.insertCategory(id: "cat-coffee", name: "Coffee", groupId: "grp-daily")

        #expect(insertion.movedSiblings == [
            SortOrder.Position(id: "cat-groceries", sortOrder: 16386),
            SortOrder.Position(id: "cat-fuel", sortOrder: 32770),
        ])
        #expect(insertion.category.sortOrder == 1)

        // The shove is written, not just reported.
        let daily = try await db.fetchCategoryGroups().first { $0.id == "grp-daily" }
        #expect(daily?.categories.map(\.name) == ["Coffee", "Groceries", "Fuel"])
    }

    @Test func categoryNamesAreUniqueWithinTheirGroup() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        #expect(throws: BudgetDatabase.CategoryWriteError.duplicateCategoryName(
            name: "groceries",
            groupName: "Daily"
        )) {
            try db.insertCategory(id: "cat-dupe", name: "groceries", groupId: "grp-daily")
        }
    }

    @Test func theSameNameIsFineInAnotherGroup() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        let insertion = try db.insertCategory(id: "cat-groceries-2", name: "Groceries", groupId: "grp-bills")
        #expect(insertion.category.groupId == "grp-bills")
    }

    @Test func categoryRenameValidationKeepsNamesUniqueWithinTheGroup() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        try db.validateCategoryRename(id: "cat-groceries", name: "Food")
        #expect(throws: BudgetDatabase.CategoryWriteError.duplicateCategoryName(
            name: "fuel",
            groupName: "Daily"
        )) {
            try db.validateCategoryRename(id: "cat-groceries", name: "fuel")
        }
    }

    @Test func anUnknownCategoryCannotBeRenamed() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        #expect(throws: BudgetDatabase.CategoryWriteError.categoryNotFound) {
            try db.validateCategoryRename(id: "cat-gone", name: "New Name")
        }
    }

    @Test func anUnknownGroupIsRefused() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        #expect(throws: BudgetDatabase.CategoryWriteError.groupNotFound) {
            try db.insertCategory(id: "cat-orphan", name: "Orphan", groupId: "grp-gone")
        }
    }

    @Test func categoryBudgetTransferAddsEveryMonthAndClearsSourceCells() async throws {
        let (db, url) = try await makeTestDatabase(
            TestSchema.categories,
            TestSchema.categoryGroups,
            TestSchema.categoryMapping,
            TestSchema.zeroBudgets,
            """
            INSERT INTO category_groups (id, name, sort_order) VALUES
                ('grp-daily', 'Daily', 16384.0),
                ('grp-bills', 'Bills', 32768.0);
            INSERT INTO categories (id, name, cat_group, sort_order) VALUES
                ('cat-groceries', 'Groceries', 'grp-daily', 16384.0),
                ('cat-fuel', 'Fuel', 'grp-daily', 32768.0),
                ('cat-coffee', 'Coffee', 'grp-bills', 16384.0);
            INSERT INTO category_mapping (id, transferId) VALUES
                ('cat-groceries', 'cat-groceries'),
                ('cat-fuel', 'cat-fuel'),
                ('cat-coffee', 'cat-coffee');
            INSERT INTO zero_budgets (id, month, category, amount) VALUES
                ('202601-cat-groceries', 202601, 'cat-groceries', 12500),
                ('202601-cat-fuel', 202601, 'cat-fuel', -1000),
                ('202601-cat-coffee', 202601, 'cat-coffee', 5000),
                ('202602-cat-groceries', 202602, 'cat-groceries', 2500),
                ('202602-cat-coffee', 202602, 'cat-coffee', 4000);
            """
        )
        defer { cleanup(url) }

        let writes = try db.categoryBudgetTransferWrites(
            sourceCategoryIds: ["cat-groceries", "cat-fuel"],
            toCategoryId: "cat-coffee"
        )

        #expect(writes.count == 5)
        #expect(writes.contains {
            $0.monthInt == 202_601 && $0.categoryId == "cat-coffee" && $0.amount == 16500 && !$0.createsRow
        })
        #expect(writes.contains {
            $0.monthInt == 202_602 && $0.categoryId == "cat-coffee" && $0.amount == 6500 && !$0.createsRow
        })
        #expect(writes.filter { $0.categoryId == "cat-groceries" || $0.categoryId == "cat-fuel" }
            .allSatisfy { $0.amount == 0 && !$0.createsRow })
    }

    @Test func categoryTransferForwardsAliasesToTheSurvivingCategory() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(
                sql: "INSERT INTO categories (id, name, cat_group, sort_order) VALUES ('cat-coffee', 'Coffee', 'grp-bills', 49152.0)"
            )
            try conn.execute(
                sql: "INSERT INTO category_mapping (id, transferId) VALUES ('cat-old', 'cat-groceries')"
            )
        }

        let updates = try db.categoryMappingsForTransfer(
            sourceCategoryIds: ["cat-groceries", "cat-fuel"],
            toCategoryId: "cat-coffee"
        )

        #expect(updates.map(\.id) == ["cat-fuel", "cat-groceries", "cat-old"])
        #expect(updates.allSatisfy { $0.targetId == "cat-coffee" })
    }

    @Test func categoryTransferIsRequiredForTransactionsOrNonzeroBudgetAmounts() async throws {
        let (db, url) = try await makeTestDatabase(
            TestSchema.categories,
            TestSchema.categoryGroups,
            TestSchema.categoryMapping,
            TestSchema.transactions,
            TestSchema.zeroBudgets,
            """
            INSERT INTO category_groups (id, name, sort_order) VALUES ('grp-daily', 'Daily', 16384.0);
            INSERT INTO categories (id, name, cat_group, sort_order) VALUES ('cat-groceries', 'Groceries', 'grp-daily', 16384.0);
            INSERT INTO category_mapping (id, transferId) VALUES
                ('cat-groceries', 'cat-groceries'),
                ('cat-old', 'cat-groceries');
            INSERT INTO transactions (id, category, tombstone) VALUES ('txn-old', 'cat-old', 0);
            """
        )
        defer { cleanup(url) }

        #expect(try await db.categoryRequiresTransfer(id: "cat-groceries"))

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: "UPDATE transactions SET tombstone = 1 WHERE id = 'txn-old'")
            try conn.execute(
                sql: "INSERT INTO zero_budgets (id, month, category, amount) VALUES ('202601-cat-groceries', 202601, 'cat-groceries', 2500)"
            )
        }
        #expect(try await db.categoryRequiresTransfer(id: "cat-groceries"))

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: "UPDATE zero_budgets SET amount = 0 WHERE category = 'cat-groceries'")
        }
        let requiresTransfer = try await db.categoryRequiresTransfer(id: "cat-groceries")
        #expect(!requiresTransfer)
    }

    @Test func legacyMappedBudgetAmountsAreTransferredAndStalePlansAreRejected() async throws {
        let (db, url) = try await makeTestDatabase(
            TestSchema.categories,
            TestSchema.categoryGroups,
            TestSchema.categoryMapping,
            TestSchema.zeroBudgets,
            """
            INSERT INTO category_groups (id, name, sort_order) VALUES
                ('grp-source', 'Source', 16384.0),
                ('grp-target', 'Target', 32768.0);
            INSERT INTO categories (id, name, cat_group, sort_order) VALUES
                ('cat-food', 'Food', 'grp-source', 16384.0),
                ('cat-target', 'Target', 'grp-target', 16384.0);
            INSERT INTO category_mapping (id, transferId) VALUES
                ('cat-food', 'cat-food'),
                ('cat-target', 'cat-target'),
                ('legacy-food', 'cat-food');
            INSERT INTO zero_budgets (id, month, category, amount) VALUES
                ('202601-cat-food', 202601, 'cat-food', 2000),
                ('202601-legacy-food', 202601, 'legacy-food', 3000),
                ('202601-cat-target', 202601, 'cat-target', 4000);
            """
        )
        defer { cleanup(url) }

        #expect(try await db.categoryRequiresTransfer(id: "cat-food"))

        let plan = try db.categoryTransferPlan(
            sourceCategoryIds: ["cat-food"],
            toCategoryId: "cat-target"
        )
        #expect(plan.budgetWrites.contains {
            $0.rowId == "202601-cat-target" && $0.amount == 9000 && !$0.createsRow
        })
        #expect(plan.budgetWrites.contains {
            $0.rowId == "202601-legacy-food" && $0.amount == 0 && !$0.createsRow
        })
        #expect(plan.mappings.contains {
            $0.id == "legacy-food" && $0.targetId == "cat-target"
        })
        #expect(try db.categoryTransferPlanMatches(
            sourceCategoryIds: ["cat-food"],
            toCategoryId: "cat-target",
            expected: plan
        ))

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(
                sql: "UPDATE zero_budgets SET amount = 6000 WHERE id = '202601-cat-target'"
            )
        }
        #expect(try db.categoryTransferPlanMatches(
            sourceCategoryIds: ["cat-food"],
            toCategoryId: "cat-target",
            expected: plan
        ) == false)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: "UPDATE categories SET tombstone = 1 WHERE id = 'cat-food'")
        }
        #expect(throws: BudgetDatabase.CategoryWriteError.categoryNotFound) {
            try db.categoryTransferPlan(
                sourceCategoryIds: ["cat-food"],
                toCategoryId: "cat-target"
            )
        }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: "UPDATE categories SET tombstone = 0 WHERE id = 'cat-food'")
            try conn.execute(sql: "UPDATE categories SET tombstone = 1 WHERE id = 'cat-target'")
        }
        #expect(throws: BudgetDatabase.CategoryWriteError.categoryNotFound) {
            try db.categoryTransferPlan(
                sourceCategoryIds: ["cat-food"],
                toCategoryId: "cat-target"
            )
        }
    }
}
