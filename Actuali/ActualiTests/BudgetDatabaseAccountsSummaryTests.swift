import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins the semantics of `fetchAccountsMonthSummary()`, the accounts tab's
/// summary group (GH #256): the same income and spending the budget tab
/// reports for the month — categorised transactions in on-budget accounts,
/// hidden categories and groups left out, split parents excluded.
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

                INSERT INTO category_groups (id, name, is_income, sort_order) VALUES
                    ('grp-income', 'Income',     1, 1.0),
                    ('grp-usual',  'Usual',      0, 2.0);

                INSERT INTO categories (id, name, is_income, cat_group, sort_order) VALUES
                    ('cat-salary', 'Salary',   1, 'grp-income', 1.0),
                    ('cat-rent',   'Rent',     0, 'grp-usual',  1.0),
                    ('cat-food',   'Food',     0, 'grp-usual',  2.0);
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

                INSERT INTO transactions (id, acct, category, amount, date, tombstone) VALUES
                    ('pay',     'acct-1', 'cat-salary', 400000, 20260803, 0),
                    ('rent',    'acct-1', 'cat-rent',  -150000, 20260805, 0),
                    ('coffee',  'acct-1', 'cat-food',     -450, 20260806, 0),
                    ('refund',  'acct-1', 'cat-food',      450, 20260807, 0),  -- offsets the coffee
                    ('void',    'acct-1', 'cat-food',    -9999, 20260807, 1),  -- tombstoned
                    ('lastmo',  'acct-1', 'cat-rent',   -20000, 20260731, 0),  -- previous month
                    ('nextmo',  'acct-1', 'cat-salary',  10000, 20260901, 0);  -- next month
            """)
        }

        let summary = try await db.fetchAccountsMonthSummary(month: "2026-08")

        #expect(summary.incomeCents == 400000)
        #expect(summary.expenseCents == 150000)
        #expect(summary.netCents == 250000)
    }

    @Test func countsOnBudgetAccountsOnly() async throws {
        // The figures have to agree with the budget tab's Income/Spent, which
        // ignores off-budget accounts entirely (GH #256 follow-up). Closed
        // on-budget accounts still count; a deleted one doesn't, so a
        // transaction orphaned on it can't leak into every future month.
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget, closed, sort_order, tombstone) VALUES
                    ('acct-on',     'Checking',  0, 0, 1.0, 0),
                    ('acct-off',    'Brokerage', 1, 0, 2.0, 0),
                    ('acct-closed', 'Old Card',  0, 1, 3.0, 0),
                    ('acct-dead',   'Deleted',   0, 0, 4.0, 1);

                INSERT INTO transactions (id, acct, category, amount, date, tombstone) VALUES
                    ('salary',   'acct-on',     'cat-salary', 300000, 20260803, 0),
                    ('dividend', 'acct-off',    'cat-salary',   5000, 20260804, 0),
                    ('fee',      'acct-closed', 'cat-food',    -1200, 20260805, 0),
                    ('ghost',    'acct-dead',   'cat-food',  -100000, 20260806, 0);
            """)
        }

        let summary = try await db.fetchAccountsMonthSummary(month: "2026-08")

        #expect(summary.incomeCents == 300000)
        #expect(summary.expenseCents == 1200)
    }

    @Test func ignoresUncategorisedTransactionsAndTransferLegs() async throws {
        // Transfers between on-budget accounts carry no category, so they drop
        // out with everything else uncategorised. A categorised leg into an
        // off-budget account is spending, the way upstream counts it.
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget, sort_order) VALUES
                    ('acct-checking', 'Checking',  0, 1.0),
                    ('acct-savings',  'Savings',   0, 2.0),
                    ('acct-broker',   'Brokerage', 1, 3.0);

                INSERT INTO transactions (id, acct, category, amount, date, transferred_id, tombstone) VALUES
                    ('spend',     'acct-checking', 'cat-food',  -2500, 20260805, NULL,        0),
                    ('uncat',     'acct-checking', NULL,        -7000, 20260805, NULL,        0),
                    ('leg-out',   'acct-checking', NULL,       -50000, 20260806, 'leg-in',    0),
                    ('leg-in',    'acct-savings',  NULL,        50000, 20260806, 'leg-out',   0),
                    ('to-broker', 'acct-checking', 'cat-food', -30000, 20260807, 'from-chk',  0),
                    ('from-chk',  'acct-broker',   NULL,        30000, 20260807, 'to-broker', 0);
            """)
        }

        let summary = try await db.fetchAccountsMonthSummary(month: "2026-08")

        #expect(summary.incomeCents == 0)
        #expect(summary.expenseCents == 32500)
    }

    @Test func excludesHiddenCategoriesAndGroups() async throws {
        // The budget tab's totals skip hidden categories and hidden groups, so
        // these have to skip them too or the two tabs disagree.
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, sort_order) VALUES ('acct-1', 'Checking', 1.0);

                INSERT INTO category_groups (id, name, is_income, sort_order, hidden) VALUES
                    ('grp-hidden', 'Archived', 0, 3.0, 1);
                INSERT INTO categories (id, name, is_income, cat_group, sort_order, hidden, tombstone) VALUES
                    ('cat-hidden',   'Old Bill',   0, 'grp-usual',  3.0, 1, 0),
                    ('cat-in-hidden','Archived',   0, 'grp-hidden', 1.0, 0, 0),
                    ('cat-dead',     'Deleted',    0, 'grp-usual',  4.0, 0, 1),
                    ('cat-old-pay',  'Old Salary', 1, 'grp-income', 2.0, 1, 0);

                INSERT INTO transactions (id, acct, category, amount, date, tombstone) VALUES
                    ('rent',   'acct-1', 'cat-rent',      -150000, 20260805, 0),
                    ('pay',    'acct-1', 'cat-salary',     400000, 20260803, 0),
                    ('hidden', 'acct-1', 'cat-hidden',      -5000, 20260805, 0),
                    ('inhid',  'acct-1', 'cat-in-hidden',   -6000, 20260805, 0),
                    ('dead',   'acct-1', 'cat-dead',        -7000, 20260805, 0),
                    ('oldpay', 'acct-1', 'cat-old-pay',      8000, 20260805, 0);
            """)
        }

        let summary = try await db.fetchAccountsMonthSummary(month: "2026-08")

        #expect(summary.incomeCents == 400000)
        #expect(summary.expenseCents == 150000)
    }

    @Test func countsSplitChildrenButNotTheirParent() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, sort_order) VALUES ('acct-1', 'Checking', 1.0);

                -- A -$100.00 purchase split into -$60.00 and -$40.00. The
                -- parent keeps the category it had before the split, so
                -- counting it too would report $200.00 of expenses.
                INSERT INTO transactions (id, acct, category, amount, date, isParent, isChild, parent_id, tombstone) VALUES
                    ('split-parent', 'acct-1', 'cat-food', -10000, 20260803, 1, 0, NULL,           0),
                    ('split-c1',     'acct-1', 'cat-food',  -6000, 20260803, 0, 1, 'split-parent', 0),
                    ('split-c2',     'acct-1', 'cat-rent',  -4000, 20260803, 0, 1, 'split-parent', 0);

                -- A deleted split: only the parent is tombstoned, so its
                -- children have to be excluded through it.
                INSERT INTO transactions (id, acct, category, amount, date, isParent, isChild, parent_id, tombstone) VALUES
                    ('dead-parent', 'acct-1', 'cat-food', -3000, 20260804, 1, 0, NULL,          1),
                    ('orphan-c1',   'acct-1', 'cat-food', -3000, 20260804, 0, 1, 'dead-parent', 0);
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
                INSERT INTO transactions (id, acct, category, amount, date, tombstone) VALUES
                    ('t1', 'acct-1', 'cat-salary', 1000, 20260701, 0);
            """)
        }

        let summary = try await db.fetchAccountsMonthSummary(month: "2026-08")

        #expect(summary == BudgetDatabase.AccountsMonthSummary())
        #expect(summary.netCents == 0)
    }
}
