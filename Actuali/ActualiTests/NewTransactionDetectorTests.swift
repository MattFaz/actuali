import Foundation
import GRDB
import Testing
@testable import Actuali

struct NewTransactionDetectorTests {

    private let localNode = "aaaaaaaaaaaaaaaa"
    private let serverNode = "bbbbbbbbbbbbbbbb"
    private let budgetId = "test-budget"

    /// Upstream schema subset: the transaction display joins plus
    /// messages_crdt, which drives creation detection. The returned queue
    /// writes fixtures to the same file the BudgetDatabase reads.
    private func makeDatabase() throws -> (BudgetDatabase, DatabaseQueue) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    acct TEXT,
                    category TEXT,
                    amount INTEGER,
                    description TEXT,
                    notes TEXT,
                    date INTEGER,
                    imported_description TEXT,
                    transferred_id TEXT,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    parent_id TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    type TEXT,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: "CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER DEFAULT 0)")
            try db.execute(sql: "CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT)")
            try db.execute(sql: "CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT, tombstone INTEGER DEFAULT 0)")
            try db.execute(sql: "CREATE TABLE category_mapping (id TEXT PRIMARY KEY, transferId TEXT)")
            try db.execute(sql: """
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                )
                """)
            try db.execute(sql: "INSERT INTO accounts (id, name) VALUES ('acct1', 'Checking')")
        }
        return (try BudgetDatabase(path: tempURL), queue)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "NewTransactionDetectorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Insert a transaction row plus its creation messages, attributed to
    /// `node`, the way a sync (or local write) populates messages_crdt.
    private func insertTransaction(_ queue: DatabaseQueue, id: String,
                                   category: String? = nil, node: String) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO transactions (id, acct, amount, date, category) VALUES (?, 'acct1', -1250, 20260707, ?)",
                arguments: [id, category])
            for (i, column) in ["acct", "amount", "date"].enumerated() {
                let ts = String(format: "2026-07-07T00:00:00.%03dZ-0000-%@", i, node)
                try db.execute(
                    sql: "INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES (?, 'transactions', ?, ?, x'00')",
                    arguments: ["\(id)-\(ts)", id, column])
            }
        }
    }

    private func editTransaction(_ queue: DatabaseQueue, id: String, node: String) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES (?, 'transactions', ?, 'notes', x'00')",
                arguments: ["\(id)-edit-2026-07-07T00:00:09.000Z-0000-\(node)", id])
        }
    }

    @Test func firstRunReportsNothingEvenWithExistingServerTransactions() async throws {
        let (database, queue) = try makeDatabase()
        try insertTransaction(queue, id: "t1", node: serverNode)
        let detector = NewTransactionDetector(defaults: makeDefaults())

        let found = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode)

        #expect(found.isEmpty)
    }

    @Test func detectsServerTransactionOnceThenGoesQuiet() async throws {
        let (database, queue) = try makeDatabase()
        let detector = NewTransactionDetector(defaults: makeDefaults())
        _ = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode)

        try insertTransaction(queue, id: "t1", node: serverNode)

        let first = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode)
        let second = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode)

        #expect(first.map(\.id) == ["t1"])
        #expect(second.isEmpty)
    }

    @Test func ignoresLocallyCreatedTransactions() async throws {
        let (database, queue) = try makeDatabase()
        let detector = NewTransactionDetector(defaults: makeDefaults())
        _ = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode)

        try insertTransaction(queue, id: "local1", node: localNode)

        let found = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode)

        #expect(found.isEmpty)
    }

    @Test func ignoresServerEditsToExistingTransactions() async throws {
        let (database, queue) = try makeDatabase()
        try insertTransaction(queue, id: "t1", node: serverNode)
        let detector = NewTransactionDetector(defaults: makeDefaults())
        _ = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode)

        try editTransaction(queue, id: "t1", node: serverNode)

        let found = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode)

        #expect(found.isEmpty)
    }

    @Test func watermarkSurvivesDetectorRecreation() async throws {
        let (database, queue) = try makeDatabase()
        let defaults = makeDefaults()
        _ = try await NewTransactionDetector(defaults: defaults).detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode)

        try insertTransaction(queue, id: "t1", node: serverNode)

        let first = try await NewTransactionDetector(defaults: defaults).detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode)
        let second = try await NewTransactionDetector(defaults: defaults).detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode)

        #expect(first.map(\.id) == ["t1"])
        #expect(second.isEmpty)
    }

    /// A re-downloaded budget file resets messages_crdt ids, leaving the
    /// stored watermark ahead of the database. The detector must re-seed
    /// rather than spuriously notify (or miss forever).
    @Test func reseedsWhenWatermarkIsAheadOfDatabase() async throws {
        let (bigDatabase, bigQueue) = try makeDatabase()
        for i in 1...3 {
            try insertTransaction(bigQueue, id: "t\(i)", node: serverNode)
        }
        let defaults = makeDefaults()
        let detector = NewTransactionDetector(defaults: defaults)
        _ = try await detector.detectNewTransactions(
            in: bigDatabase, budgetId: budgetId, localNode: localNode)

        // Fresh download: same budget id, far fewer messages.
        let (freshDatabase, freshQueue) = try makeDatabase()
        try insertTransaction(freshQueue, id: "t1", node: serverNode)

        let found = try await detector.detectNewTransactions(
            in: freshDatabase, budgetId: budgetId, localNode: localNode)

        #expect(found.isEmpty)

        // And detection still works going forward from the new baseline.
        try insertTransaction(freshQueue, id: "t9", node: serverNode)
        let next = try await detector.detectNewTransactions(
            in: freshDatabase, budgetId: budgetId, localNode: localNode)
        #expect(next.map(\.id) == ["t9"])
    }
}
