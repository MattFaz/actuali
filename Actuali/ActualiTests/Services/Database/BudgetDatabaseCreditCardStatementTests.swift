import Foundation
import Testing
import GRDB
@testable import Actuali

@MainActor
struct BudgetDatabaseCreditCardStatementTests {

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
                    closed INTEGER DEFAULT 0,
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
                    schedule TEXT,
                    transferred_id TEXT,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0,
                    parent_id TEXT
                );
            """)
        }
        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func fetchCreditCardStatementDueCalculatesUnpaidAndPaidStatements() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        // Setup:
        // Statement closes on 20260215 with $500.00 debt (-50000 cents).
        // On 20260220, user spends $200.00 (-20000 cents).
        // Live balance is -70000 cents (-$700.00).
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, tombstone, isParent, isChild, parent_id) VALUES
                    ('t1', 'card1', -30000, 20260201, 0, 0, 0, NULL),   -- before statement ($300)
                    ('t2', 'card1', -20000, 20260215, 0, 0, 0, NULL),   -- on statement date ($200)
                    ('t3', 'card1', -20000, 20260220, 0, 0, 0, NULL);   -- new cycle spend ($200)
            """)
        }

        let statementDate = DayDate(year: 2026, month: 2, day: 15)

        // Case 1: Before payment, statement balance is $500, remaining due is $500, live balance is $700.
        let resultsBefore = try await db.fetchCreditCardStatementDues(for: [
            (accountId: "card1", statementDate: statementDate, liveBalance: -70000)
        ])
        let dueBeforePayment = resultsBefore["card1"]!
        #expect(dueBeforePayment.statementBalance == 50000)
        #expect(dueBeforePayment.paymentsSince == 0)
        #expect(dueBeforePayment.remainingDue == 50000)
        #expect(dueBeforePayment.isPaid == false)

        // Case 2: User makes a $500 payment (+50000) on 20260225. Live balance is now -20000 (-$200.00).
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, tombstone, isParent, isChild, parent_id) VALUES
                    ('t4', 'card1', 50000, 20260225, 0, 0, 0, NULL);
            """)
        }

        let resultsAfter = try await db.fetchCreditCardStatementDues(for: [
            (accountId: "card1", statementDate: statementDate, liveBalance: -20000)
        ])
        let dueAfterPayment = resultsAfter["card1"]!
        #expect(dueAfterPayment.statementBalance == 50000)
        #expect(dueAfterPayment.paymentsSince == 50000)
        #expect(dueAfterPayment.remainingDue == 0)
        #expect(dueAfterPayment.isPaid == true)
    }

    @Test func fetchCreditCardStatementDuesBatchHandlesMultipleCards() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, tombstone, isParent, isChild, parent_id) VALUES
                    ('c1_t1', 'card1', -40000, 20260115, 0, 0, 0, NULL),
                    ('c2_t1', 'card2', -15000, 20260110, 0, 0, 0, NULL);
            """)
        }

        let results = try await db.fetchCreditCardStatementDues(for: [
            (accountId: "card1", statementDate: DayDate(year: 2026, month: 1, day: 15), liveBalance: -40000),
            (accountId: "card2", statementDate: DayDate(year: 2026, month: 1, day: 10), liveBalance: -15000)
        ])

        #expect(results["card1"]?.statementBalance == 40000)
        #expect(results["card1"]?.remainingDue == 40000)
        #expect(results["card2"]?.statementBalance == 15000)
        #expect(results["card2"]?.remainingDue == 15000)
    }

    @Test func fetchRecentStatementsReturnsOnlyStatementsWithData() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        // Cycle 1: 2026-07-16 to 2026-08-15 (closing 2026-08-15)
        // Cycle 2: 2026-06-16 to 2026-07-15 (closing 2026-07-15)
        // Cycle 3: 2026-05-16 to 2026-06-15 (closing 2026-06-15) - empty, no transactions
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, tombstone, isParent, isChild, parent_id) VALUES
                    ('t_c2_1', 'card1', -25000, 20260620, 0, 0, 0, NULL),
                    ('t_c2_2', 'card1', -15000, 20260701, 0, 0, 0, NULL),
                    ('t_pay_c2', 'card1', 40000, 20260720, 0, 0, 0, NULL),
                    ('t_c1_1', 'card1', -30000, 20260801, 0, 0, 0, NULL);
            """)
        }

        let cycles = [
            (start: DayDate(year: 2026, month: 7, day: 16), end: DayDate(year: 2026, month: 8, day: 15), dueDate: DayDate(year: 2026, month: 9, day: 9)),
            (start: DayDate(year: 2026, month: 6, day: 16), end: DayDate(year: 2026, month: 7, day: 15), dueDate: DayDate(year: 2026, month: 8, day: 9)),
            (start: DayDate(year: 2026, month: 5, day: 16), end: DayDate(year: 2026, month: 6, day: 15), dueDate: DayDate(year: 2026, month: 7, day: 10))
        ]

        let records = try await db.fetchRecentStatements(
            accountId: "card1",
            cycles: cycles,
            liveBalance: -30000
        )

        // Cycle 3 has no transactions and 0 balance, so only 2 records are returned
        #expect(records.count == 2)

        // Most recent statement (Cycle 1)
        #expect(records[0].statementDate == DayDate(year: 2026, month: 8, day: 15))
        #expect(records[0].statementBalance == 30000)
        #expect(records[0].totalSpend == 30000)
        #expect(records[0].transactionCount == 2)
        #expect(records[0].remainingDue == 30000)
        #expect(records[0].isPaid == false)

        // Older statement (Cycle 2)
        #expect(records[1].statementDate == DayDate(year: 2026, month: 7, day: 15))
        #expect(records[1].statementBalance == 40000)
        #expect(records[1].totalSpend == 40000)
        #expect(records[1].paymentsSince == 40000)
        #expect(records[1].remainingDue == 0)
        #expect(records[1].isPaid == true)
        #expect(records[1].transactionCount == 2)
    }

    @Test func fetchTransactionsWithDateRangeFiltersAccurately() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, tombstone, isParent, isChild, parent_id, sort_order) VALUES
                    ('t_before', 'card1', -1000, 20260610, 0, 0, 0, NULL, 1),
                    ('t_start',  'card1', -2000, 20260616, 0, 0, 0, NULL, 2),
                    ('t_mid',    'card1', -3000, 20260701, 0, 0, 0, NULL, 3),
                    ('t_end',    'card1', -4000, 20260715, 0, 0, 0, NULL, 4),
                    ('t_after',  'card1', -5000, 20260716, 0, 0, 0, NULL, 5);
            """)
        }

        let txs = try await db.fetchTransactions(
            accountId: "card1",
            startDate: 20260616,
            endDate: 20260715
        )

        #expect(txs.count == 3)
        let ids = txs.map(\.id)
        #expect(ids == ["t_end", "t_mid", "t_start"])
    }
}
