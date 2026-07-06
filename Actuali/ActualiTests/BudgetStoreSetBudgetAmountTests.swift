import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreSetBudgetAmountTests {

    /// Full schema fetchBudgetMonth needs (matches BudgetDatabaseRolloverTests)
    /// plus messages_crdt for the sync write path.
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
                INSERT INTO category_mapping (id, transferId) VALUES ('cat-groceries', 'cat-groceries');
                INSERT INTO accounts (id, name, offbudget) VALUES ('acct-1', 'Checking', 0);
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

    // MARK: - Amount parsing (pure)

    @Test func parsesDollarsToCents() throws {
        #expect(try BudgetStore.budgetAmountCents(from: "25.50") == 2550)
    }

    @Test func parsesZero() throws {
        #expect(try BudgetStore.budgetAmountCents(from: "0") == 0)
    }

    @Test func rejectsUnparseableAmount() {
        #expect(throws: BudgetStoreError.invalidAmount) {
            try BudgetStore.budgetAmountCents(from: "not a number")
        }
    }

    @Test func rejectsNegativeAmount() {
        #expect(throws: BudgetStoreError.invalidAmount) {
            try BudgetStore.budgetAmountCents(from: "-5")
        }
    }

    // MARK: - End-to-end save

    @Test func settingBudgetPersistsAndRefreshesMonth() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await store.setBudgetAmount(month: "2026-07", categoryId: "cat-groceries", amountCents: 2550)

        let queue = try DatabaseQueue(path: path.path)
        let rows = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM zero_budgets")
        }
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["id"] == "202607-cat-groceries")
        #expect(row["amount"] == 2550)

        // The published month must reflect the edit without a manual refresh.
        let month = try #require(store.currentBudgetMonth)
        #expect(month.month == "2026-07")
        let groceries = try #require(month.categoryBudgets.first { $0.categoryId == "cat-groceries" })
        #expect(groceries.budgeted == 2550)
    }

    @Test func withoutSyncClientThrowsSyncNotConfigured() async throws {
        let store = BudgetStore.previewInstance()

        await #expect(throws: BudgetStoreError.syncNotConfigured) {
            try await store.setBudgetAmount(month: "2026-07", categoryId: "cat-1", amountCents: 100)
        }
    }
}
