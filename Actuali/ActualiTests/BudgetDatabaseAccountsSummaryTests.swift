import Foundation
import XCTest
import GRDB
@testable import Actuali

/// Pins the semantics of `fetchAccountsMonthSummary()`, the accounts tab's
/// summary group (GH #256): money in and out across every account for one
/// month, transfer legs excluded, split parents excluded, other months out.
@MainActor
struct BudgetDatabaseAccountsSummaryTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")

        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    type TEXT,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    acct TEXT,
                    category TEXT,
                    description TEXT,
                    amount INTEGER,
                    date INTEGER,
                    transferred_id TEXT,
                    sort_order REAL,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    parent_id TEXT,
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
            """)
        }
        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func sumsIncomeAndExpensesForTheRequestedMonthOnly() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, sort_order) VALUES ('acct-1', 'Checking', 1.0);

                INSERT INTO transactions (id, acct, amount, date, tombstone) VALUES
                    ('pay',     'acct-1', 400000, 20260803, 0),
                    ('rent',    'acct-1', -150000, 20260805, 0),
                    ('coffee',  'acct-1',   -450, 20260806, 0),
                    ('void',    'acct-1',  -9999, 20260807, 1),  -- tombstoned
                    ('lastmo',  'acct-1', -20000, 20260731, 0),  -- previous month
                    ('nextmo',  'acct-1',  10000, 20260901, 0);  -- next month
            """)
        }

        let summary = try await db.fetchAccountsMonthSummary(month: "2026-08")

        #expect(summary.incomeCents == 400000)
        #expect(summary.expenseCents == 150450)
        #expect(summary.netCents == 249550)
    }

    @Test func coversOffBudgetAndClosedAccountsToo() async throws {
        // The card sits under the all-accounts balance, which counts every
        // account, so its month totals have to cover the same set.
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget, closed, sort_order, tombstone) VALUES
                    ('acct-on',     'Checking',  0, 0, 1.0, 0),
                    ('acct-off',    'Brokerage', 1, 0, 2.0, 0),
                    ('acct-closed', 'Old Card',  0, 1, 3.0, 0),
                    ('acct-dead',   'Deleted',   0, 0, 4.0, 1);

                INSERT INTO transactions (id, acct, amount, date, tombstone) VALUES
                    ('salary',   'acct-on',      300000, 20260803, 0),
                    ('dividend', 'acct-off',       5000, 20260804, 0),
                    ('fee',      'acct-closed',   -1200, 20260805, 0),
                    ('ghost',    'acct-dead',   -100000, 20260806, 0);
            """)
        }

        let summary = try await db.fetchAccountsMonthSummary(month: "2026-08")

        #expect(summary.incomeCents == 305000)
        #expect(summary.expenseCents == 1200)
    }

    @Test func excludesTransferLegs() async throws {
        // A transfer moves money inside the set of accounts the card totals,
        // so counting its legs would report both income and an expense that
        // never happened (same rule as the WebUI's cash flow card).
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, sort_order) VALUES
                    ('acct-checking', 'Checking', 1.0),
                    ('acct-savings',  'Savings',  2.0);

                -- Transfer payees carry no name, just the linked account.
                INSERT INTO payees (id, name, transfer_acct) VALUES
                    ('payee-shop',       'Shop', NULL),
                    ('payee-to-savings', NULL,   'acct-savings'),
                    ('payee-to-checking',NULL,   'acct-checking');
                INSERT INTO payee_mapping (id, targetId) VALUES
                    ('payee-shop',        'payee-shop'),
                    ('payee-to-savings',  'payee-to-savings'),
                    ('payee-to-checking', 'payee-to-checking');

                INSERT INTO transactions (id, acct, description, amount, date, transferred_id, tombstone) VALUES
                    ('spend',    'acct-checking', 'payee-shop',        -2500, 20260805, NULL,       0),
                    ('leg-out',  'acct-checking', 'payee-to-savings', -50000, 20260806, 'leg-in',   0),
                    ('leg-in',   'acct-savings',  'payee-to-checking', 50000, 20260806, 'leg-out',  0);
            """)
        }

        let summary = try await db.fetchAccountsMonthSummary(month: "2026-08")

        #expect(summary.incomeCents == 0)
        #expect(summary.expenseCents == 2500)
    }

    @Test func countsSplitChildrenButNotTheirParent() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, sort_order) VALUES ('acct-1', 'Checking', 1.0);

                -- A -$100.00 purchase split into -$60.00 and -$40.00. Counting
                -- the parent too would report $200.00 of expenses.
                INSERT INTO transactions (id, acct, amount, date, isParent, isChild, parent_id, tombstone) VALUES
                    ('split-parent', 'acct-1', -10000, 20260803, 1, 0, NULL,           0),
                    ('split-c1',     'acct-1',  -6000, 20260803, 0, 1, 'split-parent', 0),
                    ('split-c2',     'acct-1',  -4000, 20260803, 0, 1, 'split-parent', 0);

                -- A deleted split: only the parent is tombstoned, so its
                -- children have to be excluded through it.
                INSERT INTO transactions (id, acct, amount, date, isParent, isChild, parent_id, tombstone) VALUES
                    ('dead-parent', 'acct-1', -3000, 20260804, 1, 0, NULL,          1),
                    ('orphan-c1',   'acct-1', -3000, 20260804, 0, 1, 'dead-parent', 0);
            """)
        }

        let summary = try await db.fetchAccountsMonthSummary(month: "2026-08")

        #expect(summary.incomeCents == 0)
        #expect(summary.expenseCents == 10000)
    }

    @Test func emptyMonthIsZero() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, sort_order) VALUES ('acct-1', 'Checking', 1.0);
                INSERT INTO transactions (id, acct, amount, date, tombstone) VALUES
                    ('t1', 'acct-1', 1000, 20260701, 0);
            """)
        }

        let summary = try await db.fetchAccountsMonthSummary(month: "2026-08")

        #expect(summary == BudgetDatabase.AccountsMonthSummary())
        #expect(summary.netCents == 0)
    }
}
