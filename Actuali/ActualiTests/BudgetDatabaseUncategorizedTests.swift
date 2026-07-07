import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins the row set of `fetchUncategorizedTransactions()` /
/// `fetchUncategorizedCount()` to the WebUI's "uncategorized" pseudo-account
/// filter (desktop-client `accountFilter('uncategorized')`):
/// - on-budget account, category NULL, not a split parent
/// - transfers excluded unless the other side is off-budget (money leaving
///   the budget still needs a category)
/// - plus this codebase's hygiene rules: tombstoned rows and children of
///   tombstoned split parents never appear (GH #26).
@MainActor
struct BudgetDatabaseUncategorizedTests {

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

    @Test func includesOnlyUncategorizedOnBudgetTransactions() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget) VALUES
                    ('acct-on',  'Checking', 0),
                    ('acct-off', 'House',    1);

                INSERT INTO categories (id, name) VALUES ('cat-food', 'Food');
                INSERT INTO category_mapping (id, transferId) VALUES ('cat-food', NULL);

                INSERT INTO transactions (id, acct, category, amount, date) VALUES
                    ('t-uncat',       'acct-on',  NULL,       -550, 20260601),
                    ('t-categorized', 'acct-on',  'cat-food', -700, 20260602),
                    ('t-offbudget',   'acct-off', NULL,       -900, 20260603);
            """)
        }

        let ids = try await db.fetchUncategorizedTransactions().map(\.id)
        #expect(ids == ["t-uncat"])
        #expect(try await db.fetchUncategorizedCount() == 1)
    }

    @Test func excludesSplitParentsButIncludesUncategorizedChildren() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget) VALUES ('acct-1', 'Checking', 0);

                INSERT INTO categories (id, name) VALUES ('cat-food', 'Food');
                INSERT INTO category_mapping (id, transferId) VALUES ('cat-food', NULL);

                INSERT INTO payees (id, name) VALUES ('payee-market', 'Market');
                INSERT INTO payee_mapping (id, targetId) VALUES ('payee-market', 'payee-market');

                -- Split parents never carry a category; only children needing
                -- one should surface. The uncategorized child has no payee of
                -- its own and must display the parent's.
                INSERT INTO transactions (id, acct, category, description, amount, date, isParent, isChild, parent_id) VALUES
                    ('parent', 'acct-1', NULL,       'payee-market', -10000, 20260601, 1, 0, NULL),
                    ('c-uncat', 'acct-1', NULL,      NULL,            -6000, 20260601, 0, 1, 'parent'),
                    ('c-cat',   'acct-1', 'cat-food', NULL,           -4000, 20260601, 0, 1, 'parent');
            """)
        }

        let txns = try await db.fetchUncategorizedTransactions()
        #expect(txns.map(\.id) == ["c-uncat"])
        #expect(txns.first?.payeeName == "Market")
        #expect(try await db.fetchUncategorizedCount() == 1)
    }

    @Test func excludesTransfersUnlessOtherSideIsOffBudget() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget) VALUES
                    ('acct-checking', 'Checking', 0),
                    ('acct-savings',  'Savings',  0),
                    ('acct-house',    'House',    1);

                -- Transfer payees: name comes from the linked account.
                INSERT INTO payees (id, name, transfer_acct) VALUES
                    ('payee-savings', NULL, 'acct-savings'),
                    ('payee-house',   NULL, 'acct-house');

                INSERT INTO payee_mapping (id, targetId) VALUES
                    ('payee-savings', 'payee-savings'),
                    ('payee-house',   'payee-house');

                INSERT INTO transactions (id, acct, category, description, amount, date, transferred_id) VALUES
                    ('t-onbudget-leg', 'acct-checking', NULL, 'payee-savings', -10000, 20260601, 't-x1'),
                    ('t-to-offbudget', 'acct-checking', NULL, 'payee-house',   -20000, 20260602, 't-x2');
            """)
        }

        let txns = try await db.fetchUncategorizedTransactions()
        #expect(txns.map(\.id) == ["t-to-offbudget"])
        #expect(txns.first?.payeeName == "House")
        #expect(try await db.fetchUncategorizedCount() == 1)
    }

    @Test func excludesTombstonedRowsAndOrphanedChildren() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget) VALUES ('acct-1', 'Checking', 0);

                INSERT INTO transactions (id, acct, category, amount, date, tombstone) VALUES
                    ('t-live', 'acct-1', NULL, -100, 20260601, 0),
                    ('t-dead', 'acct-1', NULL, -200, 20260602, 1);

                -- Deleting a split tombstones only the parent; the children
                -- keep tombstone = 0 and must still be excluded.
                INSERT INTO transactions (id, acct, category, amount, date, isParent, isChild, parent_id, tombstone) VALUES
                    ('dead-parent', 'acct-1', NULL, -1000, 20260603, 1, 0, NULL,          1),
                    ('orphan-c1',   'acct-1', NULL,  -500, 20260603, 0, 1, 'dead-parent', 0);
            """)
        }

        let ids = try await db.fetchUncategorizedTransactions().map(\.id)
        #expect(ids == ["t-live"])
        #expect(try await db.fetchUncategorizedCount() == 1)
    }

    @Test func sortsNewestFirst() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget) VALUES ('acct-1', 'Checking', 0);

                INSERT INTO transactions (id, acct, category, amount, date, sort_order) VALUES
                    ('t-old',       'acct-1', NULL, -100, 20260601, 1),
                    ('t-new',       'acct-1', NULL, -200, 20260603, 1),
                    ('t-mid-late',  'acct-1', NULL, -300, 20260602, 2),
                    ('t-mid-early', 'acct-1', NULL, -400, 20260602, 1);
            """)
        }

        let ids = try await db.fetchUncategorizedTransactions().map(\.id)
        #expect(ids == ["t-new", "t-mid-late", "t-mid-early", "t-old"])
    }
}
