import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins the row set and fields of `fetchTransactionsForReports()`, which feeds
/// every dashboard widget engine:
/// - `transferAcct` must carry the payee's `transfer_acct` so report engines
///   can exclude transfers the way the WebUI does (GH #15: cash flow income
///   and expenses over 2x because transfer legs counted as both).
/// - Children of a tombstoned split parent must be excluded — deleting a
///   split tombstones only the parent, leaving live orphan child rows (same
///   rule `fetchAccounts()` already applies to balances).
@MainActor
struct BudgetDatabaseReportsFetchTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")

        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
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

    @Test func populatesTransferAcctFromPayee() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name) VALUES
                    ('acct-checking', 'Checking'),
                    ('acct-savings',  'Savings');

                INSERT INTO payees (id, name, transfer_acct) VALUES
                    ('payee-shop',     'Coffee Shop', NULL),
                    ('payee-transfer', NULL,          'acct-savings');

                INSERT INTO payee_mapping (id, targetId) VALUES
                    ('payee-shop',     'payee-shop'),
                    ('payee-transfer', 'payee-transfer');

                INSERT INTO transactions (id, acct, description, amount, date, transferred_id) VALUES
                    ('t-spend',    'acct-checking', 'payee-shop',      -550,  20260601, NULL),
                    ('t-transfer', 'acct-checking', 'payee-transfer', -10000, 20260602, 't-other-leg');
            """)
        }

        let txns = try await db.fetchTransactionsForReports()
        let spend = txns.first { $0.id == "t-spend" }
        let transfer = txns.first { $0.id == "t-transfer" }

        #expect(spend?.transferAcct == nil)
        #expect(transfer?.transferAcct == "acct-savings")
    }

    @Test func excludesSplitParentsAndOrphanedChildren() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, tombstone) VALUES
                    ('main', 'acct-1', 10000, 20260601, 0);

                -- A live split: children count, the parent must not.
                INSERT INTO transactions (id, acct, amount, date, isParent, isChild, parent_id, tombstone) VALUES
                    ('live-parent', 'acct-1', -10000, 20260602, 1, 0, NULL,          0),
                    ('live-c1',     'acct-1',  -6000, 20260602, 0, 1, 'live-parent', 0),
                    ('live-c2',     'acct-1',  -4000, 20260602, 0, 1, 'live-parent', 0);

                -- A deleted split: the parent is tombstoned but its children
                -- still carry tombstone = 0. Neither may appear in reports.
                INSERT INTO transactions (id, acct, amount, date, isParent, isChild, parent_id, tombstone) VALUES
                    ('dead-parent', 'acct-1', -1000, 20260603, 1, 0, NULL,          1),
                    ('orphan-c1',   'acct-1',  -500, 20260603, 0, 1, 'dead-parent', 0),
                    ('orphan-c2',   'acct-1',  -500, 20260603, 0, 1, 'dead-parent', 0);
            """)
        }

        let ids = try await db.fetchTransactionsForReports().map(\.id).sorted()
        #expect(ids == ["live-c1", "live-c2", "main"])
    }
}
