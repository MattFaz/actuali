import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreTransferBudgetTests {
    /// Two expense categories so there's something to move money between.
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.core + [TestSchema.zeroBudgets, """
        INSERT INTO category_groups (id, name) VALUES ('grp-1', 'Daily');
        INSERT INTO categories (id, name, cat_group) VALUES ('cat-groceries', 'Groceries', 'grp-1');
        INSERT INTO categories (id, name, cat_group) VALUES ('cat-dining', 'Dining Out', 'grp-1');
        INSERT INTO category_mapping (id, transferId) VALUES ('cat-groceries', 'cat-groceries');
        INSERT INTO category_mapping (id, transferId) VALUES ('cat-dining', 'cat-dining');
        INSERT INTO accounts (id, name, offbudget) VALUES ('acct-1', 'Checking', 0);
        INSERT INTO zero_budgets (id, month, category, amount) VALUES ('202607-cat-groceries', 202607, 'cat-groceries', 5000);
        INSERT INTO zero_budgets (id, month, category, amount) VALUES ('202607-cat-dining', 202607, 'cat-dining', 1000);
        """])
    }

    @Test func transferMovesFundsAndRefreshesMonth() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeTestStore(database: database)

        try await store.transferBudget(
            month: "2026-07",
            fromCategoryId: "cat-groceries",
            toCategoryId: "cat-dining",
            amountCents: 2000
        )

        // The published month must reflect both sides without a manual refresh.
        let month = try #require(store.currentBudgetMonth)
        #expect(month.month == "2026-07")
        let groceries = try #require(month.categoryBudgets.first { $0.categoryId == "cat-groceries" })
        let dining = try #require(month.categoryBudgets.first { $0.categoryId == "cat-dining" })
        #expect(groceries.budgeted == 3000)
        #expect(dining.budgeted == 3000)
    }

    /// Covering from "To Budget" (nil source) only raises the destination's
    /// budgeted amount — the unallocated figure recomputes on its own.
    @Test func coverFromToBudgetIncreasesOnlyDestination() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeTestStore(database: database)

        try await store.transferBudget(
            month: "2026-07",
            fromCategoryId: nil,
            toCategoryId: "cat-dining",
            amountCents: 1500
        )

        let month = try #require(store.currentBudgetMonth)
        let groceries = try #require(month.categoryBudgets.first { $0.categoryId == "cat-groceries" })
        let dining = try #require(month.categoryBudgets.first { $0.categoryId == "cat-dining" })
        #expect(groceries.budgeted == 5000)
        #expect(dining.budgeted == 2500)
    }

    @Test func rejectsNonPositiveAmount() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeTestStore(database: database)

        await #expect(throws: BudgetStoreError.transferAmountNotPositive) {
            try await store.transferBudget(
                month: "2026-07",
                fromCategoryId: "cat-groceries",
                toCategoryId: "cat-dining",
                amountCents: 0
            )
        }
    }

    @Test func rejectsSameSourceAndDestination() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeTestStore(database: database)

        await #expect(throws: BudgetStoreError.transferCategoriesMatch) {
            try await store.transferBudget(
                month: "2026-07",
                fromCategoryId: "cat-groceries",
                toCategoryId: "cat-groceries",
                amountCents: 100
            )
        }
    }

    /// Both endpoints as "To Budget" is a no-op request, caught by the same
    /// source-equals-destination guard (nil == nil).
    @Test func rejectsToBudgetOnBothSides() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeTestStore(database: database)

        await #expect(throws: BudgetStoreError.transferCategoriesMatch) {
            try await store.transferBudget(
                month: "2026-07",
                fromCategoryId: nil,
                toCategoryId: nil,
                amountCents: 100
            )
        }
    }

    @Test func withoutSyncClientThrowsSyncNotConfigured() async throws {
        let store = BudgetStore.previewInstance()

        await #expect(throws: BudgetStoreError.syncNotConfigured) {
            try await store.transferBudget(
                month: "2026-07",
                fromCategoryId: "cat-1",
                toCategoryId: "cat-2",
                amountCents: 100
            )
        }
    }
}
