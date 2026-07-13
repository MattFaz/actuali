import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins the row set of `fetchCategoryTransactions(categoryId:month:)` to the
/// same rules as the budget month's per-category "Spent" figure (GH #56), so
/// the pushed list reconciles with the number the user tapped:
/// - effective category (through category_mapping) matches
/// - split children included (that's where split spend lives), parents
///   excluded even when a pre-split category lingers on the parent row
/// - tombstoned rows, children of tombstoned parents, and off-budget
///   accounts never appear
/// - optional "yyyy-MM" month narrows to that month; nil means all time.
@MainActor
struct BudgetDatabaseCategoryTransactionsTests {

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

    @Test func returnsAllTimeMatchesWhenMonthIsNil() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget) VALUES ('acct-1', 'Checking', 0);

                INSERT INTO categories (id, name) VALUES
                    ('cat-food', 'Food'),
                    ('cat-fun',  'Fun');
                INSERT INTO category_mapping (id, transferId) VALUES
                    ('cat-food', NULL),
                    ('cat-fun',  NULL);

                INSERT INTO transactions (id, acct, category, amount, date) VALUES
                    ('t-june',  'acct-1', 'cat-food', -550, 20260601),
                    ('t-jan',   'acct-1', 'cat-food', -700, 20260115),
                    ('t-fun',   'acct-1', 'cat-fun',  -900, 20260602),
                    ('t-uncat', 'acct-1', NULL,       -300, 20260603);
            """)
        }

        let txns = try await db.fetchCategoryTransactions(categoryId: "cat-food", month: nil)
        #expect(txns.map(\.id) == ["t-june", "t-jan"])
        #expect(txns.first?.categoryName == "Food")
    }

    @Test func narrowsToSingleMonthWhenProvided() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget) VALUES ('acct-1', 'Checking', 0);

                INSERT INTO categories (id, name) VALUES ('cat-food', 'Food');
                INSERT INTO category_mapping (id, transferId) VALUES ('cat-food', NULL);

                INSERT INTO transactions (id, acct, category, amount, date) VALUES
                    ('t-may-31',  'acct-1', 'cat-food', -100, 20260531),
                    ('t-june-1',  'acct-1', 'cat-food', -200, 20260601),
                    ('t-june-30', 'acct-1', 'cat-food', -300, 20260630),
                    ('t-july-1',  'acct-1', 'cat-food', -400, 20260701);
            """)
        }

        let txns = try await db.fetchCategoryTransactions(categoryId: "cat-food", month: "2026-06")
        #expect(txns.map(\.id) == ["t-june-30", "t-june-1"])
    }

    @Test func includesSplitChildrenWithParentPayeeAndExcludesParents() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget) VALUES ('acct-1', 'Checking', 0);

                INSERT INTO categories (id, name) VALUES
                    ('cat-food', 'Food'),
                    ('cat-fun',  'Fun');
                INSERT INTO category_mapping (id, transferId) VALUES
                    ('cat-food', NULL),
                    ('cat-fun',  NULL);

                INSERT INTO payees (id, name) VALUES ('payee-market', 'Market');
                INSERT INTO payee_mapping (id, targetId) VALUES ('payee-market', 'payee-market');

                -- A transaction categorized BEFORE being split keeps its
                -- category on the parent row (Actual only masks it in the
                -- view layer). Counting the parent alongside its child would
                -- double the month's spend, so only the child may appear.
                INSERT INTO transactions (id, acct, category, description, amount, date, isParent, isChild, parent_id) VALUES
                    ('parent',  'acct-1', 'cat-food', 'payee-market', -10000, 20260601, 1, 0, NULL),
                    ('c-food',  'acct-1', 'cat-food', NULL,            -6000, 20260601, 0, 1, 'parent'),
                    ('c-fun',   'acct-1', 'cat-fun',  NULL,            -4000, 20260601, 0, 1, 'parent');
            """)
        }

        let txns = try await db.fetchCategoryTransactions(categoryId: "cat-food", month: nil)
        #expect(txns.map(\.id) == ["c-food"])
        #expect(txns.first?.payeeName == "Market")
    }

    @Test func excludesTombstonedRowsOrphanedChildrenAndOffBudgetAccounts() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget) VALUES
                    ('acct-on',  'Checking', 0),
                    ('acct-off', 'House',    1);

                INSERT INTO categories (id, name) VALUES ('cat-food', 'Food');
                INSERT INTO category_mapping (id, transferId) VALUES ('cat-food', NULL);

                INSERT INTO transactions (id, acct, category, amount, date, tombstone) VALUES
                    ('t-live',      'acct-on',  'cat-food', -100, 20260601, 0),
                    ('t-dead',      'acct-on',  'cat-food', -200, 20260602, 1),
                    ('t-offbudget', 'acct-off', 'cat-food', -300, 20260603, 0);

                -- Deleting a split tombstones only the parent; its children
                -- keep tombstone = 0 and must still be excluded.
                INSERT INTO transactions (id, acct, category, amount, date, isParent, isChild, parent_id, tombstone) VALUES
                    ('dead-parent', 'acct-on', NULL,       -1000, 20260604, 1, 0, NULL,          1),
                    ('orphan-c1',   'acct-on', 'cat-food',  -500, 20260604, 0, 1, 'dead-parent', 0);
            """)
        }

        let ids = try await db.fetchCategoryTransactions(categoryId: "cat-food", month: nil).map(\.id)
        #expect(ids == ["t-live"])
    }

    @Test func resolvesCategoryThroughCategoryMapping() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget) VALUES ('acct-1', 'Checking', 0);

                INSERT INTO categories (id, name) VALUES ('cat-food', 'Food');
                -- 'cat-old' was merged into 'cat-food'; rows still pointing at
                -- the old id must surface under the surviving category.
                INSERT INTO category_mapping (id, transferId) VALUES
                    ('cat-food', NULL),
                    ('cat-old',  'cat-food');

                INSERT INTO transactions (id, acct, category, amount, date) VALUES
                    ('t-direct', 'acct-1', 'cat-food', -100, 20260602),
                    ('t-mapped', 'acct-1', 'cat-old',  -200, 20260601);
            """)
        }

        let txns = try await db.fetchCategoryTransactions(categoryId: "cat-food", month: nil)
        #expect(txns.map(\.id) == ["t-direct", "t-mapped"])
        #expect(txns.map(\.categoryName) == ["Food", "Food"])
    }

    @Test func sortsNewestFirst() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget) VALUES ('acct-1', 'Checking', 0);

                INSERT INTO categories (id, name) VALUES ('cat-food', 'Food');
                INSERT INTO category_mapping (id, transferId) VALUES ('cat-food', NULL);

                INSERT INTO transactions (id, acct, category, amount, date, sort_order) VALUES
                    ('t-old',       'acct-1', 'cat-food', -100, 20260601, 1),
                    ('t-new',       'acct-1', 'cat-food', -200, 20260603, 1),
                    ('t-mid-late',  'acct-1', 'cat-food', -300, 20260602, 2),
                    ('t-mid-early', 'acct-1', 'cat-food', -400, 20260602, 1);
            """)
        }

        let ids = try await db.fetchCategoryTransactions(categoryId: "cat-food", month: nil).map(\.id)
        #expect(ids == ["t-new", "t-mid-late", "t-mid-early", "t-old"])
    }
}
