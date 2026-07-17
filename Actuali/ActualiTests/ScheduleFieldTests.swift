import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins the `transactions.schedule` column mapping: posted scheduled
/// transactions link back to their schedule so the poster's dedup guard
/// (`WHERE schedule = ? AND date >= ?`) can find them.
@MainActor
struct ScheduleFieldTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
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
                    schedule TEXT,
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

    private func makeTransaction(schedule: String?) -> Transaction {
        Transaction(
            id: "txn-1",
            accountId: "acct-1",
            date: 20260115,
            amount: -1500,
            payeeId: nil,
            payeeName: nil,
            categoryId: nil,
            categoryName: nil,
            notes: "posted by schedule",
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: 1,
            importedPayee: nil,
            schedule: schedule
        )
    }

    @Test func scheduleFieldRoundTripsThroughDatabase() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: "INSERT INTO accounts (id, name) VALUES ('acct-1', 'Checking')")
        }

        try db.insertTransaction(makeTransaction(schedule: "sched-123"))

        let fetched = try await db.fetchTransactions(accountId: "acct-1")
        #expect(fetched.count == 1)
        #expect(fetched.first?.schedule == "sched-123")
    }

    @Test func scheduleFieldDefaultsToNil() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try db.insertTransaction(makeTransaction(schedule: nil))

        let fetched = try await db.fetchTransactions()
        #expect(fetched.count == 1)
        #expect(fetched.first?.schedule == nil)
    }

    @Test func syncableFieldsIncludeSchedule() {
        let transaction = makeTransaction(schedule: "sched-123")
        #expect(transaction.syncableFields["schedule"] as? String == "sched-123")
    }
}
