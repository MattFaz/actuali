import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins the status-filter chips on the transaction lists (GH #439):
/// All / Uncategorized / Uncleared / Cleared / Reconciled. The filter runs in
/// SQL so pages stay full-sized and cover full history, composes with the
/// account scope, search, and paging, and takes precedence over the legacy
/// hide-cleared / hide-reconciled toggles — an explicit filter is its own
/// visibility rule, the same precedent as the Budget tab. `cleared` means
/// cleared-but-not-reconciled: with `uncleared` and `reconciled` the three
/// status chips partition the list, matching the row status dot.
@MainActor
struct BudgetDatabaseTransactionStatusFilterTests {

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
                    financial_id TEXT,
                    transferred_id TEXT,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    sort_order REAL,
                    parent_id TEXT,
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
                INSERT INTO accounts (id, name, offbudget) VALUES
                    ('acct-1', 'Checking', 0),
                    ('acct-2', 'Savings', 0),
                    ('acct-off', 'Brokerage', 1);

                INSERT INTO payees (id, name, transfer_acct) VALUES
                    ('payee-market',       'Market', NULL),
                    ('payee-transfer-on',  NULL, 'acct-2'),
                    ('payee-transfer-off', NULL, 'acct-off');
                INSERT INTO payee_mapping (id, targetId) VALUES
                    ('payee-market',       'payee-market'),
                    ('payee-transfer-on',  'payee-transfer-on'),
                    ('payee-transfer-off', 'payee-transfer-off');

                INSERT INTO categories (id, name) VALUES ('cat-1', 'Food');
            """)
        }
    }

    private func seedStatuses(_ db: BudgetDatabase) async throws {
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, sort_order, cleared, reconciled) VALUES
                    ('t-pending',    'acct-1', 'payee-market', -1000, 20260603, 3, 0, 0),
                    ('t-cleared',    'acct-1', 'payee-market', -2000, 20260602, 2, 1, 0),
                    ('t-reconciled', 'acct-1', 'payee-market', -3000, 20260601, 1, 1, 1);
            """)
        }
    }

    @Test func allReturnsEveryStatus() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)
        try await seedStatuses(db)

        let all = try await db.fetchTransactions(statusFilter: .all)
        #expect(all.map(\.id) == ["t-pending", "t-cleared", "t-reconciled"])
    }

    @Test func unclearedKeepsOnlyUnclearedRows() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)
        try await seedStatuses(db)

        let uncleared = try await db.fetchTransactions(statusFilter: .uncleared)
        #expect(uncleared.map(\.id) == ["t-pending"])
    }

    @Test func clearedExcludesReconciledRows() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)
        try await seedStatuses(db)

        let cleared = try await db.fetchTransactions(statusFilter: .cleared)
        #expect(cleared.map(\.id) == ["t-cleared"])
    }

    @Test func reconciledKeepsOnlyReconciledRows() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)
        try await seedStatuses(db)

        let reconciled = try await db.fetchTransactions(statusFilter: .reconciled)
        #expect(reconciled.map(\.id) == ["t-reconciled"])
    }

    @Test func explicitStatusFilterOverridesLegacyHideToggles() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)
        try await seedStatuses(db)

        // Uncleared chip with "hide cleared" already on (a no-op on an
        // uncleared-only list) still shows the uncleared row.
        let uncleared = try await db.fetchTransactions(
            statusFilter: .uncleared, unclearedOnly: true, hideReconciled: true
        )
        #expect(uncleared.map(\.id) == ["t-pending"])

        // Reconciled chip beats both legacy hide flags.
        let reconciled = try await db.fetchTransactions(
            statusFilter: .reconciled, unclearedOnly: true, hideReconciled: true
        )
        #expect(reconciled.map(\.id) == ["t-reconciled"])

        // Cleared chip beats hide-reconciled and does not drag reconciled in.
        let cleared = try await db.fetchTransactions(
            statusFilter: .cleared, unclearedOnly: true, hideReconciled: true
        )
        #expect(cleared.map(\.id) == ["t-cleared"])
    }

    @Test func uncategorizedMatchesTheUncategorizedListFilter() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, category, description, amount, date, sort_order, isParent, tombstone, cleared) VALUES
                    ('t-plain',            'acct-1',  NULL,    'payee-market',       -1000, 20260606, 6, 0, 0, 0),
                    ('t-cleared-plain',    'acct-1',  NULL,    'payee-market',       -1000, 20260605, 5, 0, 0, 1),
                    ('t-categorized',      'acct-1',  'cat-1', 'payee-market',       -2000, 20260604, 4, 0, 0, 0),
                    ('t-offbudget',        'acct-off', NULL,   'payee-market',       -3000, 20260603, 3, 0, 0, 0),
                    ('t-transfer-on',      'acct-1',  NULL,    'payee-transfer-on',  -4000, 20260602, 2, 0, 0, 0),
                    ('t-transfer-off',     'acct-1',  NULL,    'payee-transfer-off', -5000, 20260601, 1, 0, 0, 0),
                    ('t-split-parent',     'acct-1',  NULL,    'payee-market',       -6000, 20260531, 0, 1, 0, 0),
                    ('t-tombstoned',       'acct-1',  NULL,    'payee-market',       -7000, 20260530, 0, 0, 1, 0);
            """)
        }

        let uncategorized = try await db.fetchTransactions(statusFilter: .uncategorized)
        #expect(uncategorized.map(\.id) == ["t-plain", "t-cleared-plain", "t-transfer-off"])
    }

    /// The list renders a split as one collapsed parent row and drops the
    /// children, so the chip must surface a parent with a live uncategorized
    /// child — the dedicated Uncategorized list counts the child instead and
    /// stays parent-free (BudgetDatabaseUncategorizedTests). A parent whose
    /// children are all categorized or dead matches nothing, and a live row
    /// on a missing account is a sync-race orphan both surfaces exclude.
    /// The transfer rule belongs to each child: an on-budget transfer needs
    /// no category, regardless of the parent's payee.
    @Test func uncategorizedChipIncludesSplitParentsWithUncategorizedChildren() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, category, description, amount, date, sort_order, isParent, isChild, parent_id, tombstone) VALUES
                    ('t-split-mixed',     'acct-1', NULL,   'payee-market', -1000, 20260605, 7, 1, 0, NULL, 0),
                    ('t-split-mixed-c',   'acct-1', 'cat-1', NULL,           0,     20260605, 7, 0, 1, 't-split-mixed', 0),
                    ('t-split-mixed-u',   'acct-1', NULL,   NULL,           0,     20260605, 7, 0, 1, 't-split-mixed', 0),
                    ('t-split-categorized', 'acct-1', NULL, 'payee-market', -2000, 20260604, 6, 1, 0, NULL, 0),
                    ('t-split-cat-c',     'acct-1', 'cat-1', NULL,           0,     20260604, 6, 0, 1, 't-split-categorized', 0),
                    ('t-split-dead',      'acct-1', NULL,   'payee-market', -3000, 20260603, 5, 1, 0, NULL, 0),
                    ('t-split-dead-u',    'acct-1', NULL,   NULL,           0,     20260603, 5, 0, 1, 't-split-dead', 1),
                    ('t-split-on-transfer', 'acct-1', NULL, 'payee-market', -4000, 20260602, 4, 1, 0, NULL, 0),
                    ('t-split-on-transfer-cat', 'acct-1', 'cat-1', 'payee-market', 0, 20260602, 4, 0, 1, 't-split-on-transfer', 0),
                    ('t-split-on-transfer-c', 'acct-1', NULL, 'payee-transfer-on', 0, 20260602, 4, 0, 1, 't-split-on-transfer', 0),
                    ('t-split-parent-transfer', 'acct-1', NULL, 'payee-transfer-on', -5000, 20260601, 3, 1, 0, NULL, 0),
                    ('t-split-parent-transfer-cat', 'acct-1', 'cat-1', 'payee-market', 0, 20260601, 3, 0, 1, 't-split-parent-transfer', 0),
                    ('t-split-parent-transfer-c', 'acct-1', NULL, 'payee-market', 0, 20260601, 3, 0, 1, 't-split-parent-transfer', 0),
                    ('t-split-off-transfer', 'acct-1', NULL, 'payee-market', -6000, 20260531, 2, 1, 0, NULL, 0),
                    ('t-split-off-transfer-cat', 'acct-1', 'cat-1', 'payee-market', 0, 20260531, 2, 0, 1, 't-split-off-transfer', 0),
                    ('t-split-off-transfer-c', 'acct-1', NULL, 'payee-transfer-off', 0, 20260531, 2, 0, 1, 't-split-off-transfer', 0),
                    ('t-orphan-acct',     'acct-gone', NULL, 'payee-market', -4000, 20260602, 4, 0, 0, NULL, 0);
                """)
        }

        let uncategorized = try await db.fetchTransactions(statusFilter: .uncategorized)
        #expect(uncategorized.map(\.id) == [
            "t-split-mixed", "t-split-parent-transfer", "t-split-off-transfer"
        ])
    }

    @Test func uncategorizedComposesWithSearchAndPaging() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        // Cafe rows interleaved with market ones: paging must index into the
        // filtered set, and search must not resurrect the market rows.
        let values = [
            "('t-cafe-3', 'acct-1', 'payee-market', -1000, 20260605, 5)",
            "('t-market-2', 'acct-1', 'payee-market', -1000, 20260604, 4)",
            "('t-cafe-2', 'acct-1', 'payee-market', -1000, 20260603, 3)",
            "('t-market-1', 'acct-1', 'payee-market', -1000, 20260602, 2)",
            "('t-cafe-1', 'acct-1', 'payee-market', -1000, 20260601, 1)"
        ].joined(separator: ",\n")
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, sort_order)
                VALUES \(values);
            """)
        }
        // Name only the cafe rows' payee so search has something to match on.
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO payees (id, name) VALUES ('payee-cafe', 'Cafe');
                INSERT INTO payee_mapping (id, targetId) VALUES ('payee-cafe', 'payee-cafe');
                UPDATE transactions SET description = 'payee-cafe'
                 WHERE id IN ('t-cafe-3', 't-cafe-2', 't-cafe-1');
            """)
        }

        let pageOne = try await db.fetchTransactions(
            limit: 2, offset: 0, search: "cafe", statusFilter: .uncategorized
        )
        #expect(pageOne.map(\.id) == ["t-cafe-3", "t-cafe-2"])

        let pageTwo = try await db.fetchTransactions(
            limit: 2, offset: 2, search: "cafe", statusFilter: .uncategorized
        )
        #expect(pageTwo.map(\.id) == ["t-cafe-1"])
    }

    @Test func statusFilterComposesWithAccountScope() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, sort_order, cleared) VALUES
                    ('t-cleared-1',  'acct-1', 'payee-market', -1000, 20260603, 3, 1),
                    ('t-cleared-2',  'acct-2', 'payee-market', -2000, 20260602, 2, 1),
                    ('t-uncleared',  'acct-1', 'payee-market', -3000, 20260601, 1, 0);
            """)
        }

        let cleared = try await db.fetchTransactions(
            accountId: "acct-1", statusFilter: .cleared
        )
        #expect(cleared.map(\.id) == ["t-cleared-1"])
    }
}
