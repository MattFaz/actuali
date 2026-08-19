import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreTransferBudgetTests {

    /// Full schema fetchBudgetMonth needs (matches BudgetStoreSetBudgetAmountTests)
    /// plus messages_crdt for the sync write path, and two expense categories
    /// so there's something to move money between.
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

                CREATE TABLE zero_budgets (
                    id TEXT PRIMARY KEY,
                    month INTEGER,
                    category TEXT,
                    amount INTEGER DEFAULT 0,
                    carryover INTEGER DEFAULT 0
                );

                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                );

                INSERT INTO category_groups (id, name) VALUES ('grp-1', 'Daily');
                INSERT INTO categories (id, name, cat_group) VALUES ('cat-groceries', 'Groceries', 'grp-1');
                INSERT INTO categories (id, name, cat_group) VALUES ('cat-dining', 'Dining Out', 'grp-1');
                INSERT INTO category_mapping (id, transferId) VALUES ('cat-groceries', 'cat-groceries');
                INSERT INTO category_mapping (id, transferId) VALUES ('cat-dining', 'cat-dining');
                INSERT INTO accounts (id, name, offbudget) VALUES ('acct-1', 'Checking', 0);
                INSERT INTO zero_budgets (id, month, category, amount) VALUES ('202607-cat-groceries', 202607, 'cat-groceries', 5000);
                INSERT INTO zero_budgets (id, month, category, amount) VALUES ('202607-cat-dining', 202607, 'cat-dining', 1000);
            """)
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func makeStore(database: BudgetDatabase) async throws -> BudgetStore {
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)
        return store
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func transferMovesFundsAndRefreshesMonth() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

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
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

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
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

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
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

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
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

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
