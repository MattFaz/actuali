import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins the `transactions.schedule` column mapping: posted scheduled
/// transactions link back to their schedule so the poster's dedup guard
/// (`WHERE schedule = ? AND date >= ?`) can find them.
@MainActor
struct ScheduleFieldTests {

    /// Builds the fetch-path tables. `includeScheduleColumn: false` mimics an
    /// old snapshot whose `transactions` table predates the schedule column,
    /// so opening `BudgetDatabase` must backfill it via migration.
    private func makeDatabase(includeScheduleColumn: Bool = true) throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")

        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    offbudget INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE payees (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    transfer_acct TEXT,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE payee_mapping (
                    id TEXT PRIMARY KEY,
                    targetId TEXT
                );

                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
                );

                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    acct TEXT,
                    category TEXT,
                    description TEXT,
                    amount INTEGER,
                    notes TEXT,
                    date INTEGER,
                    imported_description TEXT,
                    transferred_id TEXT,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    sort_order REAL,
                    parent_id TEXT,
                    financial_id TEXT,
                    \(includeScheduleColumn ? "schedule TEXT," : "")
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                );
            """)
        }
        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func seedLookups(_ db: BudgetDatabase) async throws {
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name) VALUES ('acct-1', 'Checking');
                INSERT INTO categories (id, name) VALUES ('cat-food', 'Food');
                INSERT INTO category_mapping (id, transferId) VALUES ('cat-food', NULL);
            """)
        }
    }

    private func makeTransaction(
        id: String = "txn-1",
        categoryId: String? = nil,
        isParent: Bool = false,
        parentId: String? = nil,
        sortOrder: Double = 1,
        schedule: String?
    ) -> Transaction {
        Transaction(
            id: id,
            accountId: "acct-1",
            date: 20260115,
            amount: -1500,
            payeeId: nil,
            payeeName: nil,
            categoryId: categoryId,
            categoryName: nil,
            notes: "posted by schedule",
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: isParent,
            parentId: parentId,
            tombstone: false,
            sortOrder: sortOrder,
            importedPayee: nil,
            schedule: schedule
        )
    }

    @Test func scheduleFieldRoundTripsThroughDatabase() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        try db.insertTransaction(makeTransaction(schedule: "sched-123"))

        let fetched = try await db.fetchTransactions(accountId: "acct-1")
        #expect(fetched.count == 1)
        #expect(fetched.first?.schedule == "sched-123")
    }

    @Test func scheduleFieldDefaultsToNil() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        try db.insertTransaction(makeTransaction(schedule: nil))

        let fetched = try await db.fetchTransactions()
        #expect(fetched.count == 1)
        #expect(fetched.first?.schedule == nil)
    }

    /// A regression in any single row-mapping site would silently drop the
    /// column, so assert the round-trip through the other fetch paths too:
    /// child, category, and reports fetches all see a split child's schedule.
    @Test func scheduleSurvivesEveryFetchSite() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        try db.insertTransaction(makeTransaction(id: "txn-p", isParent: true, sortOrder: 2, schedule: "sched-123"))
        try db.insertTransaction(makeTransaction(
            id: "txn-c", categoryId: "cat-food", parentId: "txn-p", sortOrder: 1, schedule: "sched-123"
        ))

        let children = try await db.fetchChildTransactions(parentId: "txn-p")
        #expect(children.map(\.schedule) == ["sched-123"])

        let byCategory = try await db.fetchCategoryTransactions(categoryId: "cat-food", month: nil)
        #expect(byCategory.map(\.schedule) == ["sched-123"])

        let forReports = try await db.fetchTransactionsForReports()
        #expect(forReports.first { $0.id == "txn-c" }?.schedule == "sched-123")
    }

    /// The path real users' older files take: the snapshot predates the
    /// schedule column, so opening the database must ALTER it in before any
    /// insert/fetch — otherwise every transaction SELECT would throw.
    @Test func migrationBackfillsScheduleColumnOnLegacySnapshot() async throws {
        let (db, url) = try makeDatabase(includeScheduleColumn: false)
        defer { cleanup(url) }
        try await seedLookups(db)

        try db.insertTransaction(makeTransaction(schedule: "sched-123"))

        let fetched = try await db.fetchTransactions(accountId: "acct-1")
        #expect(fetched.count == 1)
        #expect(fetched.first?.schedule == "sched-123")
    }

    @Test func syncableFieldsIncludeSchedule() {
        let transaction = makeTransaction(schedule: "sched-123")
        #expect(transaction.syncableFields["schedule"] as? String == "sched-123")
    }
}
