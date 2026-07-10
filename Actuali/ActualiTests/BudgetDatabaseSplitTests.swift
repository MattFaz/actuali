import Foundation
import Testing
import GRDB
@testable import Actuali

/// Split transaction behavior at the database layer (GH #47):
/// - the transaction list resolves a payee for split parents whose payee
///   lives on the children (previously displayed as "Unknown")
/// - `fetchChildTransactions` returns a parent's live children for display
/// - `insertSplit` writes parent + children + CRDT messages atomically
@MainActor
struct BudgetDatabaseSplitTests {

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

    private func seedPayees(_ db: BudgetDatabase) async throws {
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name) VALUES ('acct-1', 'Checking');

                INSERT INTO payees (id, name) VALUES
                    ('payee-market', 'Market'),
                    ('payee-cafe',   'Cafe');
                INSERT INTO payee_mapping (id, targetId) VALUES
                    ('payee-market', 'payee-market'),
                    ('payee-cafe',   'payee-cafe');

                INSERT INTO categories (id, name) VALUES
                    ('cat-food', 'Food'),
                    ('cat-fun',  'Fun');
                INSERT INTO category_mapping (id, transferId) VALUES
                    ('cat-food', NULL),
                    ('cat-fun',  NULL);
            """)
        }
    }

    // MARK: - Parent payee fallback in the transaction list

    @Test func parentWithOwnPayeeShowsIt() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedPayees(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, isParent, isChild, parent_id) VALUES
                    ('parent', 'acct-1', 'payee-market', -10000, 20260601, 1, 0, NULL),
                    ('c-1',    'acct-1', 'payee-cafe',    -6000, 20260601, 0, 1, 'parent'),
                    ('c-2',    'acct-1', NULL,            -4000, 20260601, 0, 1, 'parent');
            """)
        }

        let txns = try await db.fetchTransactions()
        #expect(txns.map(\.id) == ["parent"])
        #expect(txns.first?.payeeName == "Market")
        #expect(txns.first?.isParent == true)
    }

    @Test func parentWithoutPayeeFallsBackToSingleChildPayee() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedPayees(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, isParent, isChild, parent_id) VALUES
                    ('parent', 'acct-1', NULL,           -10000, 20260601, 1, 0, NULL),
                    ('c-1',    'acct-1', 'payee-market',  -6000, 20260601, 0, 1, 'parent'),
                    ('c-2',    'acct-1', 'payee-market',  -4000, 20260601, 0, 1, 'parent');
            """)
        }

        let txns = try await db.fetchTransactions()
        #expect(txns.map(\.id) == ["parent"])
        #expect(txns.first?.payeeName == "Market")
    }

    @Test func parentFallbackIgnoresChildrenWithoutPayee() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedPayees(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, isParent, isChild, parent_id) VALUES
                    ('parent', 'acct-1', NULL,           -10000, 20260601, 1, 0, NULL),
                    ('c-1',    'acct-1', 'payee-market',  -6000, 20260601, 0, 1, 'parent'),
                    ('c-2',    'acct-1', NULL,            -4000, 20260601, 0, 1, 'parent');
            """)
        }

        let txns = try await db.fetchTransactions()
        #expect(txns.first?.payeeName == "Market")
    }

    @Test func parentWithMixedChildPayeesResolvesNoPayee() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedPayees(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, isParent, isChild, parent_id) VALUES
                    ('parent', 'acct-1', NULL,           -10000, 20260601, 1, 0, NULL),
                    ('c-1',    'acct-1', 'payee-market',  -6000, 20260601, 0, 1, 'parent'),
                    ('c-2',    'acct-1', 'payee-cafe',    -4000, 20260601, 0, 1, 'parent');
            """)
        }

        // Mixed payees can't be summarized in one name; the UI labels the
        // row "Split" when a parent resolves no payee.
        let txns = try await db.fetchTransactions()
        #expect(txns.map(\.id) == ["parent"])
        #expect(txns.first?.payeeName == nil)
    }

    @Test func parentFallbackIgnoresTombstonedChildren() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedPayees(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, description, amount, date, isParent, isChild, parent_id, tombstone) VALUES
                    ('parent', 'acct-1', NULL,           -10000, 20260601, 1, 0, NULL,     0),
                    ('c-1',    'acct-1', 'payee-market',  -6000, 20260601, 0, 1, 'parent', 0),
                    ('c-dead', 'acct-1', 'payee-cafe',    -4000, 20260601, 0, 1, 'parent', 1);
            """)
        }

        let txns = try await db.fetchTransactions()
        #expect(txns.first?.payeeName == "Market")
    }

    // MARK: - Parent split portions in the transaction list

    @Test func parentCarriesChildPortionsInEntryOrder() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedPayees(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, category, description, amount, date, isParent, isChild, parent_id, sort_order, tombstone) VALUES
                    ('parent',  'acct-1', NULL,      'payee-market', -10000, 20260601, 1, 0, NULL,     10, 0),
                    ('c-first', 'acct-1', 'cat-fun',  NULL,           -6000, 20260601, 0, 1, 'parent',  9, 0),
                    ('c-second','acct-1', 'cat-food', NULL,           -3000, 20260601, 0, 1, 'parent',  8, 0),
                    ('c-third', 'acct-1', 'cat-food', NULL,           -1000, 20260601, 0, 1, 'parent',  7, 0),
                    ('c-dead',  'acct-1', 'cat-food', NULL,            -500, 20260601, 0, 1, 'parent',  6, 1);
            """)
        }

        // One portion per live child, in entry order, for the list caption.
        let txns = try await db.fetchTransactions()
        #expect(txns.map(\.id) == ["parent"])
        #expect(txns.first?.splitPortions == [
            .init(categoryName: "Fun", amount: -6000),
            .init(categoryName: "Food", amount: -3000),
            .init(categoryName: "Food", amount: -1000)
        ])
    }

    @Test func uncategorizedChildrenAppearAsUnnamedPortions() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedPayees(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, category, description, amount, date, isParent, isChild, parent_id, sort_order) VALUES
                    ('parent', 'acct-1', NULL, 'payee-market', -10000, 20260601, 1, 0, NULL,     10),
                    ('c-1',    'acct-1', NULL, NULL,            -6000, 20260601, 0, 1, 'parent',  9),
                    ('c-2',    'acct-1', NULL, NULL,            -4000, 20260601, 0, 1, 'parent',  8);
            """)
        }

        let txns = try await db.fetchTransactions()
        #expect(txns.first?.splitPortions == [
            .init(categoryName: nil, amount: -6000),
            .init(categoryName: nil, amount: -4000)
        ])
    }

    @Test func nonParentsCarryNoPortions() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedPayees(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, category, description, amount, date) VALUES
                    ('plain', 'acct-1', 'cat-food', 'payee-market', -500, 20260601);
            """)
        }

        let txns = try await db.fetchTransactions()
        #expect(txns.first?.splitPortions == nil)
    }

    // MARK: - fetchChildTransactions

    @Test func fetchChildTransactionsReturnsLiveChildrenInEntryOrder() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seedPayees(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, category, description, amount, date, isParent, isChild, parent_id, sort_order, tombstone) VALUES
                    ('parent',  'acct-1', NULL,       'payee-market', -10000, 20260601, 1, 0, NULL,     10, 0),
                    ('c-first', 'acct-1', 'cat-food', NULL,            -6000, 20260601, 0, 1, 'parent',  9, 0),
                    ('c-second','acct-1', 'cat-fun',  'payee-cafe',    -4000, 20260601, 0, 1, 'parent',  8, 0),
                    ('c-dead',  'acct-1', 'cat-fun',  NULL,            -1000, 20260601, 0, 1, 'parent',  7, 1),
                    ('other',   'acct-1', 'cat-food', NULL,            -2000, 20260601, 0, 0, NULL,      6, 0);
            """)
        }

        let children = try await db.fetchChildTransactions(parentId: "parent")
        #expect(children.map(\.id) == ["c-first", "c-second"])
        #expect(children.map(\.categoryName) == ["Food", "Fun"])
        #expect(children.map(\.amount) == [-6000, -4000])
        #expect(children[1].payeeName == "Cafe")
        #expect(children.allSatisfy { $0.parentId == "parent" })
    }

    // MARK: - insertSplit atomicity

    private func transaction(
        id: String,
        amount: Int,
        payeeId: String? = nil,
        categoryId: String? = nil,
        isParent: Bool = false,
        parentId: String? = nil,
        sortOrder: Double? = nil
    ) -> Transaction {
        Transaction(
            id: id,
            accountId: "acct-1",
            date: 20260610,
            amount: amount,
            payeeId: payeeId,
            payeeName: nil,
            categoryId: categoryId,
            categoryName: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: isParent,
            parentId: parentId,
            tombstone: false,
            sortOrder: sortOrder,
            importedPayee: nil
        )
    }

    private func messages(for transactions: [Transaction]) -> [CRDTMessage] {
        var millis: Int64 = 1_700_000_000_000
        var result: [CRDTMessage] = []
        for txn in transactions {
            for (column, value) in txn.syncableFields {
                result.append(CRDTMessage(
                    timestamp: HLCTimestamp(millis: millis, counter: 0, node: "89e0e8e90b203f9e"),
                    dataset: Transaction.datasetName,
                    row: txn.id,
                    column: column,
                    value: CRDTValue.serialize(value)
                ))
                millis += 1
            }
        }
        return result
    }

    @Test func insertSplitPersistsAllRowsAndMessages() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        let parent = transaction(id: "parent", amount: -1000, payeeId: "payee-market", isParent: true, sortOrder: 100)
        let children = [
            transaction(id: "c-1", amount: -600, categoryId: "cat-food", parentId: "parent", sortOrder: 99),
            transaction(id: "c-2", amount: -400, categoryId: "cat-fun", parentId: "parent", sortOrder: 98)
        ]
        let crdtMessages = messages(for: [parent] + children)

        let inserted = try db.insertSplit(parent: parent, children: children, messages: crdtMessages)
        #expect(inserted.count == crdtMessages.count)

        let queue = try DatabaseQueue(path: url.path)
        let rows = try await queue.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT id, isParent, isChild, parent_id, category, amount, sort_order
                FROM transactions ORDER BY sort_order DESC
                """)
        }
        #expect(rows.count == 3)
        #expect(rows[0]["id"] == "parent")
        #expect(rows[0]["isParent"] == 1)
        #expect(rows[0]["isChild"] == 0)
        #expect(rows[0]["category"] == nil)
        #expect(rows[1]["id"] == "c-1")
        #expect(rows[1]["isChild"] == 1)
        #expect(rows[1]["parent_id"] == "parent")
        #expect(rows[1]["amount"] == -600)
        // Explicit sort orders are respected so children keep entry order
        #expect(rows[1]["sort_order"] == 99.0)
        #expect(rows[2]["id"] == "c-2")
        #expect(rows[2]["amount"] == -400)

        let messageCount = try await queue.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messages_crdt") ?? -1
        }
        #expect(messageCount == crdtMessages.count)
    }

    @Test func childFailureRollsBackParentAndAllMessages() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        let parent = transaction(id: "parent", amount: -1000, isParent: true)
        // Same id as the parent: the child INSERT violates the primary key,
        // simulating a persistence failure mid-split.
        let children = [transaction(id: "parent", amount: -1000, parentId: "parent")]
        let crdtMessages = messages(for: [parent] + children)

        #expect(throws: (any Error).self) {
            try db.insertSplit(parent: parent, children: children, messages: crdtMessages)
        }

        let queue = try DatabaseQueue(path: url.path)
        let counts = try await queue.read { conn in
            (try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM transactions") ?? -1,
             try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messages_crdt") ?? -1)
        }
        #expect(counts == (0, 0))
    }
}
