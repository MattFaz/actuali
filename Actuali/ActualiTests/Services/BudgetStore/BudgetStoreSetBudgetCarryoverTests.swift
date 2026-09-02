import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreSetBudgetCarryoverTests {

    /// Full schema fetchBudgetMonth needs (matches BudgetStoreSetBudgetAmountTests)
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

                -- A row another client wrote under its own id: the flag must
                -- land on it rather than fork a second row for the same cell.
                INSERT INTO zero_budgets (id, month, category, amount)
                    VALUES ('other-client-row', 202607, 'cat-groceries', 1000);
                -- Overspend July by 2000 so the flag has something to roll.
                INSERT INTO transactions (id, acct, category, amount, date)
                    VALUES ('txn-1', 'acct-1', 'cat-groceries', -3000, 20260710);
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

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - Month range (pure, mirrors upstream getAllMonths)

    @Test func carryoverMonthsRunThroughTwelveMonthsPastToday() {
        let months = BudgetStore.carryoverMonths(from: "2026-07", now: date(2026, 9, 15))
        #expect(months.first == "2026-07")
        #expect(months.last == "2027-09")
        #expect(months.count == 15)
    }

    @Test func carryoverMonthsBeyondTheSheetIsJustThatMonth() {
        let months = BudgetStore.carryoverMonths(from: "2028-01", now: date(2026, 9, 15))
        #expect(months == ["2028-01"])
    }

    // MARK: - End-to-end save

    @Test func togglingRolloverFlagsEveryMonthAndCarriesOverspending() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        let queue = try DatabaseQueue(path: path.path)

        try await store.setBudgetCarryover(month: "2026-07", categoryId: "cat-groceries", enabled: true)

        let rows = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM zero_budgets ORDER BY month").map {
                BudgetRow(id: $0["id"], month: $0["month"], amount: $0["amount"], carryover: $0["carryover"])
            }
        }
        // Existing row reused (amount untouched), and one row per month
        // through the end of the sheet — the same rows the web would write.
        let july = try #require(rows.first)
        #expect(july.id == "other-client-row")
        #expect(july.amount == 1000)
        #expect(july.carryover == 1)
        #expect(rows.count == BudgetStore.carryoverMonths(from: "2026-07").count)
        #expect(rows.dropFirst().allSatisfy { $0.carryover == 1 })
        #expect(rows.dropFirst().first?.id == "202608-cat-groceries")

        // The published month reflects the flag without a manual refresh...
        let month = try #require(store.currentBudgetMonth)
        #expect(month.month == "2026-07")
        let groceries = try #require(month.categoryBudgets.first { $0.categoryId == "cat-groceries" })
        #expect(groceries.carryoverEnabled)
        #expect(groceries.available == -2000)

        // ...and the overspend now rolls into August instead of being absorbed.
        let august = try await database.fetchBudgetMonth(month: "2026-08")
        #expect(august.categoryBudgets.first { $0.categoryId == "cat-groceries" }?.available == -2000)

        try await store.setBudgetCarryover(month: "2026-07", categoryId: "cat-groceries", enabled: false)

        let flags = try await queue.read { db in
            try Int.fetchAll(db, sql: "SELECT carryover FROM zero_budgets")
        }
        #expect(flags.allSatisfy { $0 == 0 })
        let refreshed = try #require(store.currentBudgetMonth?.categoryBudgets.first { $0.categoryId == "cat-groceries" })
        #expect(!refreshed.carryoverEnabled)
        let augustOff = try await database.fetchBudgetMonth(month: "2026-08")
        #expect(augustOff.categoryBudgets.first { $0.categoryId == "cat-groceries" }?.available == 0)
    }

    @Test func withoutSyncClientThrowsSyncNotConfigured() async throws {
        let store = BudgetStore.previewInstance()

        await #expect(throws: BudgetStoreError.syncNotConfigured) {
            try await store.setBudgetCarryover(month: "2026-07", categoryId: "cat-1", enabled: true)
        }
    }
}

/// Sendable snapshot of a zero_budgets row, extracted inside the GRDB read
/// closure so no non-Sendable `Row` crosses the async boundary.
private struct BudgetRow: Sendable {
    let id: String
    let month: Int
    let amount: Int
    let carryover: Int
}
