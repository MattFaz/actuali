import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins the balance semantics of `fetchAccounts()`: every non-tombstoned,
/// non-split-parent transaction row for the account counts (split children and
/// transfer legs included, split parents excluded so splits aren't
/// double-counted), and accounts with no transactions report 0.
@MainActor
struct BudgetDatabaseAccountBalanceTests {

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
            """)
        }
        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func balancesSumNonTombstonedTransactionsPerAccount() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, sort_order) VALUES
                    ('acct-checking', 'Checking', 1.0),
                    ('acct-savings',  'Savings',  2.0);

                INSERT INTO transactions (id, acct, amount, date, tombstone) VALUES
                    ('t1', 'acct-checking',  100000, 20260501, 0),
                    ('t2', 'acct-checking',   -2550, 20260502, 0),
                    ('t3', 'acct-checking',   -9999, 20260503, 1), -- tombstoned: excluded
                    ('t4', 'acct-savings',     5000, 20260504, 0);

                -- NULL tombstone counts the same as 0
                INSERT INTO transactions (id, acct, amount, date, tombstone) VALUES
                    ('t5', 'acct-savings', 250, 20260505, NULL);
            """)
        }

        let accounts = try await db.fetchAccounts()
        let checking = accounts.first { $0.id == "acct-checking" }
        let savings = accounts.first { $0.id == "acct-savings" }

        #expect(checking?.balance == 97450)
        #expect(savings?.balance == 5250)
    }

    @Test func accountWithNoTransactionsHasZeroBalance() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, sort_order) VALUES ('acct-empty', 'Empty', 1.0);
            """)
        }

        let accounts = try await db.fetchAccounts()
        #expect(accounts.count == 1)
        #expect(accounts.first?.balance == 0)
    }

    @Test func transferLegsCountButSplitParentsAreExcluded() async throws {
        // Transfer legs count toward the balance. Split transactions are stored
        // as a parent row (full amount) plus child rows (each portion); the
        // children sum to the parent, so the balance must count the children
        // and exclude the parent — otherwise every split is double-counted
        // (GH #7: a checking account off by tens of thousands).
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, sort_order) VALUES ('acct-1', 'One', 1.0);

                -- Transfer leg + a plain transaction.
                INSERT INTO transactions (id, acct, amount, date, transferred_id, tombstone) VALUES
                    ('leg',  'acct-1', -3000, 20260501, 't-other', 0),
                    ('main', 'acct-1', 10000, 20260502, NULL, 0);

                -- A -€100.00 purchase split into -€60.00 and -€40.00. The parent
                -- carries the full -10000; counting it as well would yield -20000.
                INSERT INTO transactions (id, acct, amount, date, isParent, isChild, parent_id, tombstone) VALUES
                    ('split-parent', 'acct-1', -10000, 20260503, 1, 0, NULL,           0),
                    ('split-c1',     'acct-1',  -6000, 20260503, 0, 1, 'split-parent', 0),
                    ('split-c2',     'acct-1',  -4000, 20260503, 0, 1, 'split-parent', 0);
            """)
        }

        // -3000 (leg) + 10000 (main) - 6000 - 4000 (children) = -3000.
        // The -10000 split parent is intentionally excluded.
        let accounts = try await db.fetchAccounts()
        #expect(accounts.first?.balance == -3000)
    }

    @Test func tombstonedAccountsAreExcluded() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, sort_order, tombstone) VALUES
                    ('acct-live', 'Live', 1.0, 0),
                    ('acct-dead', 'Dead', 2.0, 1);
            """)
        }

        let accounts = try await db.fetchAccounts()
        #expect(accounts.map(\.id) == ["acct-live"])
    }

    @Test func splitChildrenOfTombstonedParentAreExcluded() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, sort_order) VALUES ('acct-1', 'One', 1.0);

                INSERT INTO transactions (id, acct, amount, date, tombstone) VALUES
                    ('main', 'acct-1', 10000, 20260502, 0);

                -- A deleted split: parent is tombstoned, but its children still
                -- carry tombstone = 0. They must not count toward the balance.
                INSERT INTO transactions (id, acct, amount, date, isParent, isChild, parent_id, tombstone) VALUES
                    ('dead-parent', 'acct-1', -1000, 20260503, 1, 0, NULL,          1),
                    ('orphan-c1',   'acct-1',  -500, 20260503, 0, 1, 'dead-parent', 0),
                    ('orphan-c2',   'acct-1',  -500, 20260503, 0, 1, 'dead-parent', 0);
            """)
        }

        // Only the live 'main' transaction counts; the orphaned children are excluded.
        let accounts = try await db.fetchAccounts()
        #expect(accounts.first?.balance == 10000)
    }
}
