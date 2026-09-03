import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins the `unclearedOnly` filter in `fetchTransactions` (GH #133): with the
/// hide-cleared toggle on, transaction lists show only uncleared rows. The
/// filter runs in SQL so pages stay full-sized and cover full history, and it
/// composes with the account scope, search, and paging.
@MainActor
struct BudgetDatabaseHideClearedTests {

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
                INSERT INTO accounts (id, name) VALUES
                    ('acct-1', 'Checking'),
                    ('acct-2', 'Savings');

                INSERT INTO payees (id, name) VALUES
                    ('payee-market', 'Market'),
                    ('payee-cafe',   'Cafe');
                INSERT INTO payee_mapping (id, targetId) VALUES
                    ('payee-market', 'payee-market'),
                    ('payee-cafe',   'payee-cafe');
            """)
        }
    }

    @Test func unclearedOnlyDropsClearedAndReconciledRows() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        // Reconciled rows are always cleared too (locking requires cleared
        // first), so the cleared filter must drop them as well.
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, sort_order, cleared, reconciled) VALUES
                    ('t-pending',    'acct-1', 'payee-market', -1000, 20260604, 4, 0, 0),
                    ('t-cleared',    'acct-1', 'payee-market', -2000, 20260603, 3, 1, 0),
                    ('t-reconciled', 'acct-1', 'payee-market', -3000, 20260602, 2, 1, 1);
            """)
        }

        let uncleared = try await db.fetchTransactions(unclearedOnly: true)
        #expect(uncleared.map(\.id) == ["t-pending"])
    }

    @Test func defaultReturnsEveryClearedState() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, sort_order, cleared) VALUES
                    ('t-pending', 'acct-1', 'payee-market', -1000, 20260602, 2, 0),
                    ('t-cleared', 'acct-1', 'payee-market', -2000, 20260601, 1, 1);
            """)
        }

        let all = try await db.fetchTransactions()
        #expect(all.map(\.id) == ["t-pending", "t-cleared"])
    }

    @Test func unclearedOnlyComposesWithAccountScopeAndSearch() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, sort_order, cleared) VALUES
                    ('t-match',         'acct-1', 'payee-cafe',   -1000, 20260604, 4, 0),
                    ('t-cleared-match', 'acct-1', 'payee-cafe',   -2000, 20260603, 3, 1),
                    ('t-other-account', 'acct-2', 'payee-cafe',   -3000, 20260602, 2, 0),
                    ('t-other-payee',   'acct-1', 'payee-market', -4000, 20260601, 1, 0);
            """)
        }

        let matches = try await db.fetchTransactions(
            accountId: "acct-1", search: "cafe", unclearedOnly: true
        )
        #expect(matches.map(\.id) == ["t-match"])
    }

    @Test func unclearedOnlyPagesOverFilteredResultSet() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        // Uncleared rows interleaved with cleared ones: offsets must index
        // into the filtered set, not the raw table, so page two picks up
        // exactly where page one ended.
        let values = (0..<6).map { i in
            "('t-\(i)', 'acct-1', 'payee-market', -1000, \(20260601 + i), \(i), \(i % 2))"
        }.joined(separator: ",\n")
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, sort_order, cleared)
                VALUES \(values);
            """)
        }

        let pageOne = try await db.fetchTransactions(limit: 2, offset: 0, unclearedOnly: true)
        #expect(pageOne.map(\.id) == ["t-4", "t-2"])

        let pageTwo = try await db.fetchTransactions(limit: 2, offset: 2, unclearedOnly: true)
        #expect(pageTwo.map(\.id) == ["t-0"])
    }
}
