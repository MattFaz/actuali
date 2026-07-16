import Foundation
import GRDB
import Testing
@testable import Actuali

/// Reconciliation flow (Discord request / actios-8oe7): cleared-balance
/// query, dot-tap cleared toggling, locking cleared transactions, and the
/// balance-adjustment transaction.
@MainActor
struct BudgetStoreReconciliationTests {

    /// transactions, payees and messages_crdt normally come from the
    /// downloaded budget file, so create them with the upstream schema
    /// (matches BudgetStoreSaveTransactionTests).
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
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
                CREATE TABLE payees (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    transfer_acct TEXT,
                    tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE payee_mapping (
                    id TEXT PRIMARY KEY,
                    targetId TEXT
                )
                """)
            // The split cascade reads children via fetchChildTransactions,
            // whose display joins touch these three tables.
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    transfer_acct TEXT,
                    tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    tombstone INTEGER DEFAULT 0
                )
                """)
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
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    /// Store wired to a real database and sync client. The server client is
    /// unconfigured, so the post-write automatic sync fails fast and locally.
    private func makeStore(database: BudgetDatabase) async throws -> BudgetStore {
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)
        return store
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func insertRow(
        _ url: URL,
        id: String,
        acct: String = "acct-1",
        amount: Int,
        cleared: Bool,
        reconciled: Bool = false,
        tombstone: Bool = false,
        isParent: Bool = false,
        parentId: String? = nil
    ) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions
                    (id, acct, amount, date, cleared, reconciled, tombstone, isParent, isChild, parent_id, sort_order)
                VALUES (?, ?, ?, 20260701, ?, ?, ?, ?, ?, ?, 1)
                """, arguments: [
                    id, acct, amount,
                    cleared ? 1 : 0, reconciled ? 1 : 0, tombstone ? 1 : 0,
                    isParent ? 1 : 0, parentId != nil ? 1 : 0, parentId
                ])
        }
    }

    private func row(_ url: URL, id: String) throws -> Row? {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM transactions WHERE id = ?", arguments: [id])
        }
    }

    private func messages(_ url: URL, column: String) throws -> [Row] {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM messages_crdt WHERE column = ? ORDER BY id",
                arguments: [column]
            )
        }
    }

    /// Struct mirror of an insertRow() row, so updateTransaction's full-row
    /// UPDATE writes back exactly what's stored. (BudgetStore.fetchTransactions
    /// needs the full budget schema — categories, accounts — which this
    /// minimal fixture doesn't create.)
    private func makeTransaction(
        id: String,
        amount: Int,
        cleared: Bool,
        reconciled: Bool = false,
        isParent: Bool = false,
        parentId: String? = nil
    ) -> Transaction {
        Transaction(
            id: id,
            accountId: "acct-1",
            date: 20260701,
            amount: amount,
            payeeId: nil,
            payeeName: nil,
            categoryId: nil,
            categoryName: nil,
            notes: nil,
            cleared: cleared,
            reconciled: reconciled,
            transferId: nil,
            isParent: isParent,
            parentId: parentId,
            tombstone: false,
            sortOrder: 1,
            importedPayee: nil
        )
    }

    // MARK: - Cleared balance

    @Test func clearedBalanceSumsOnlyClearedRowsForTheAccount() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }

        try insertRow(url, id: "t1", amount: -1000, cleared: true)
        try insertRow(url, id: "t2", amount: -500, cleared: false)            // uncleared: excluded
        try insertRow(url, id: "t3", amount: 300, cleared: true, reconciled: true) // reconciled still counts
        try insertRow(url, id: "t4", acct: "acct-2", amount: -9999, cleared: true) // other account
        try insertRow(url, id: "t5", amount: -800, cleared: true, tombstone: true) // deleted

        #expect(try await database.clearedBalance(accountId: "acct-1") == -700)
    }

    @Test func clearedBalanceCountsChildrenNotParents() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }

        // Split: parent carries the total, children the portions. Counting
        // both would double the split (same rule as the account balance).
        try insertRow(url, id: "parent", amount: -1000, cleared: true, isParent: true)
        try insertRow(url, id: "child-a", amount: -600, cleared: true, parentId: "parent")
        try insertRow(url, id: "child-b", amount: -400, cleared: true, parentId: "parent")

        #expect(try await database.clearedBalance(accountId: "acct-1") == -1000)
    }

    // MARK: - Dot tap: toggleCleared

    @Test func toggleClearedFlipsTheFlagAndEmitsMessage() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        try insertRow(url, id: "t1", amount: -500, cleared: false)
        let transaction = makeTransaction(id: "t1", amount: -500, cleared: false)

        await store.toggleCleared(transaction)

        let updated = try #require(try row(url, id: "t1"))
        #expect(updated["cleared"] == 1)
        let clearedMessages = try messages(url, column: "cleared")
        #expect(clearedMessages.count == 1)
    }

    @Test func toggleClearedOnReconciledRowUnlocksInstead() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        try insertRow(url, id: "t1", amount: -500, cleared: true, reconciled: true)
        let transaction = makeTransaction(id: "t1", amount: -500, cleared: true, reconciled: true)

        await store.toggleCleared(transaction)

        let updated = try #require(try row(url, id: "t1"))
        #expect(updated["reconciled"] == 0)
        #expect(updated["cleared"] == 1) // unlock keeps cleared
        #expect(try messages(url, column: "reconciled").count == 1)
        #expect(try messages(url, column: "cleared").isEmpty)
    }

    @Test func toggleClearedOnSplitParentCascadesToChildren() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        try insertRow(url, id: "parent", amount: -1000, cleared: false, isParent: true)
        try insertRow(url, id: "child-a", amount: -600, cleared: false, parentId: "parent")
        try insertRow(url, id: "child-b", amount: -400, cleared: false, parentId: "parent")
        let parent = makeTransaction(id: "parent", amount: -1000, cleared: false, isParent: true)

        await store.toggleCleared(parent)

        for id in ["parent", "child-a", "child-b"] {
            let updated = try #require(try row(url, id: id))
            #expect(updated["cleared"] == 1, "expected \(id) to be cleared")
        }
    }

    // MARK: - Locking

    @Test func lockClearedTransactionsMarksClearedUnreconciledRowsOnly() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        try insertRow(url, id: "cleared-1", amount: -500, cleared: true)
        try insertRow(url, id: "cleared-parent", amount: -1000, cleared: true, isParent: true)
        try insertRow(url, id: "cleared-child", amount: -1000, cleared: true, parentId: "cleared-parent")
        try insertRow(url, id: "uncleared", amount: -200, cleared: false)
        try insertRow(url, id: "already-locked", amount: -300, cleared: true, reconciled: true)
        try insertRow(url, id: "other-account", acct: "acct-2", amount: -400, cleared: true)
        try insertRow(url, id: "deleted", amount: -100, cleared: true, tombstone: true)

        let locked = await store.lockClearedTransactions(accountId: "acct-1")

        #expect(locked == 3)
        for id in ["cleared-1", "cleared-parent", "cleared-child"] {
            let updated = try #require(try row(url, id: id))
            #expect(updated["reconciled"] == 1, "expected \(id) to be locked")
        }
        for id in ["uncleared", "other-account", "deleted"] {
            let updated = try #require(try row(url, id: id))
            #expect(updated["reconciled"] == 0, "expected \(id) untouched")
        }
        // One CRDT message per newly locked row, none for the pre-locked one.
        #expect(try messages(url, column: "reconciled").count == 3)
    }

    // MARK: - Adjustment transaction

    @Test func adjustmentTransactionIsClearedWithDifferenceAmount() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        try insertRow(url, id: "t1", amount: -12000, cleared: true)
        // Bank says -100.00, cleared balance is -120.00 → adjustment of +20.00.
        let created = await store.createReconciliationAdjustment(
            accountId: "acct-1", amountCents: 2000
        )

        #expect(created)
        #expect(try await database.clearedBalance(accountId: "acct-1") == -10000)

        let queue = try DatabaseQueue(path: url.path)
        let adjustment = try #require(try queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM transactions WHERE notes = ?",
                arguments: ["Reconciliation balance adjustment"]
            )
        })
        #expect(adjustment["amount"] == 2000)
        #expect(adjustment["cleared"] == 1)
        #expect(adjustment["reconciled"] == 0)
        #expect(adjustment["acct"] == "acct-1")
    }
}
