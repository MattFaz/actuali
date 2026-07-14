import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins pagination and database-backed search in `fetchTransactions` (GH #65):
/// account pages previously loaded only the newest 100 rows and search
/// filtered that in-memory slice, so older transactions were unreachable.
/// Now the default page is 500, `offset` pages through full history, and
/// `search` pushes the TransactionSearchMatcher semantics (payee, category,
/// notes, progressive amount) into SQL so it covers every transaction.
@MainActor
struct BudgetDatabaseTransactionPagingSearchTests {

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
                    ('payee-cafe',   'Cafe'),
                    ('payee-juice',  '100% Juice'),
                    ('payee-under',  'Sale_Items'),
                    ('payee-underx', 'SaleXItems');
                INSERT INTO payee_mapping (id, targetId) VALUES
                    ('payee-market', 'payee-market'),
                    ('payee-cafe',   'payee-cafe'),
                    ('payee-juice',  'payee-juice'),
                    ('payee-under',  'payee-under'),
                    ('payee-underx', 'payee-underx');

                INSERT INTO categories (id, name) VALUES
                    ('cat-food', 'Food'),
                    ('cat-fun',  'Fun');
                INSERT INTO category_mapping (id, transferId) VALUES
                    ('cat-food', NULL),
                    ('cat-fun',  NULL);
            """)
        }
    }

    // MARK: - Paging

    @Test func defaultLimitIs500() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        // 505 transactions on consecutive dates, newest last inserted.
        let values = (0..<505).map { i in
            "('t-\(i)', 'acct-1', 'payee-market', -1000, \(20240101 + i), \(i))"
        }.joined(separator: ",\n")
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, sort_order)
                VALUES \(values);
            """)
        }

        let txns = try await db.fetchTransactions()
        #expect(txns.count == 500)
        #expect(txns.first?.id == "t-504")
    }

    @Test func offsetReturnsNextPage() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, sort_order) VALUES
                    ('t-1', 'acct-1', 'payee-market', -1000, 20260105, 5),
                    ('t-2', 'acct-1', 'payee-market', -1000, 20260104, 4),
                    ('t-3', 'acct-1', 'payee-market', -1000, 20260103, 3),
                    ('t-4', 'acct-1', 'payee-market', -1000, 20260102, 2),
                    ('t-5', 'acct-1', 'payee-market', -1000, 20260101, 1);
            """)
        }

        let page = try await db.fetchTransactions(limit: 2, offset: 2)
        #expect(page.map(\.id) == ["t-3", "t-4"])

        let pastEnd = try await db.fetchTransactions(limit: 2, offset: 10)
        #expect(pastEnd.isEmpty)
    }

    // MARK: - Search: text fields

    @Test func searchMatchesPayeeCaseInsensitivelyAcrossFullHistory() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, sort_order) VALUES
                    ('t-new', 'acct-1', 'payee-market', -1000, 20260601, 2),
                    ('t-old', 'acct-1', 'payee-cafe',   -2000, 20190101, 1);
            """)
        }

        // The cafe transaction is years older than the newest row — a
        // DB-backed search must still find it.
        let matches = try await db.fetchTransactions(search: "CAFE")
        #expect(matches.map(\.id) == ["t-old"])
    }

    @Test func searchMatchesNotesAndCategory() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, category, amount, notes, date, sort_order) VALUES
                    ('t-rent', 'acct-1', 'payee-market', 'cat-food', -1000, 'monthly rent', 20260601, 3),
                    ('t-fun',  'acct-1', 'payee-market', 'cat-fun',  -2000, NULL,           20260531, 2),
                    ('t-none', 'acct-1', 'payee-market', 'cat-food', -3000, NULL,           20260530, 1);
            """)
        }

        let byNote = try await db.fetchTransactions(search: "rent")
        #expect(byNote.map(\.id) == ["t-rent"])

        let byCategory = try await db.fetchTransactions(search: "fun")
        #expect(byCategory.map(\.id) == ["t-fun"])
    }

    @Test func searchEscapesLikeWildcards() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, sort_order) VALUES
                    ('t-juice',  'acct-1', 'payee-juice',  -1000, 20260601, 4),
                    ('t-market', 'acct-1', 'payee-market', -2000, 20260531, 3),
                    ('t-under',  'acct-1', 'payee-under',  -3000, 20260530, 2),
                    ('t-underx', 'acct-1', 'payee-underx', -4000, 20260529, 1);
            """)
        }

        // '%' must be literal: "100%" matches only "100% Juice", not everything.
        let percent = try await db.fetchTransactions(search: "100%")
        #expect(percent.map(\.id) == ["t-juice"])

        // '_' must be literal: "Sale_" matches "Sale_Items" but not "SaleXItems".
        let underscore = try await db.fetchTransactions(search: "Sale_")
        #expect(underscore.map(\.id) == ["t-under"])
    }

    // MARK: - Search: amounts

    @Test func searchMatchesAmountProgressively() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, sort_order) VALUES
                    ('t-1950', 'acct-1', 'payee-market', -1950, 20260601, 3),
                    ('t-1999', 'acct-1', 'payee-market',  1999, 20260531, 2),
                    ('t-2050', 'acct-1', 'payee-market', -2050, 20260530, 1);
            """)
        }

        // "19" matches 19.00–19.99 regardless of sign.
        let broad = try await db.fetchTransactions(search: "19")
        #expect(broad.map(\.id) == ["t-1950", "t-1999"])

        // "19.5" narrows to 19.50–19.59.
        let narrow = try await db.fetchTransactions(search: "19.5")
        #expect(narrow.map(\.id) == ["t-1950"])

        // "19.99" is exact.
        let exact = try await db.fetchTransactions(search: "19.99")
        #expect(exact.map(\.id) == ["t-1999"])
    }

    // MARK: - Search: scoping and split parents

    @Test func searchRespectsAccountFilter() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, sort_order) VALUES
                    ('t-checking', 'acct-1', 'payee-cafe', -1000, 20260601, 2),
                    ('t-savings',  'acct-2', 'payee-cafe', -2000, 20260531, 1);
            """)
        }

        let matches = try await db.fetchTransactions(accountId: "acct-2", search: "cafe")
        #expect(matches.map(\.id) == ["t-savings"])
    }

    @Test func searchResolvesSplitParentPayeeFromChildren() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        // Parent carries no payee of its own; both live children agree on
        // Cafe, so the list shows the parent as "Cafe" — searching "cafe"
        // must therefore surface the parent row.
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, isParent, isChild, parent_id, sort_order) VALUES
                    ('parent', 'acct-1', NULL,          -10000, 20260601, 1, 0, NULL,     3),
                    ('c-1',    'acct-1', 'payee-cafe',   -6000, 20260601, 0, 1, 'parent', 2),
                    ('c-2',    'acct-1', 'payee-cafe',   -4000, 20260601, 0, 1, 'parent', 1),
                    ('other',  'acct-1', 'payee-market', -1000, 20260531, 0, 0, NULL,     0);
            """)
        }

        let matches = try await db.fetchTransactions(search: "cafe")
        #expect(matches.map(\.id) == ["parent"])
    }

    @Test func searchAppliesLimitAndOffset() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedLookups(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, sort_order) VALUES
                    ('t-1', 'acct-1', 'payee-cafe',   -1000, 20260603, 4),
                    ('t-2', 'acct-1', 'payee-cafe',   -1000, 20260602, 3),
                    ('t-3', 'acct-1', 'payee-cafe',   -1000, 20260601, 2),
                    ('t-4', 'acct-1', 'payee-market', -1000, 20260531, 1);
            """)
        }

        let secondPage = try await db.fetchTransactions(limit: 2, offset: 2, search: "cafe")
        #expect(secondPage.map(\.id) == ["t-3"])
    }
}
