import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreDuplicationTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-dup-\(UUID().uuidString).sqlite")
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
                    financial_id TEXT,
                    transferred_id TEXT,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    parent_id TEXT,
                    schedule TEXT
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
            try db.execute(sql: """
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT,
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
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                INSERT INTO accounts (id, name, offbudget, closed, sort_order, tombstone)
                VALUES ('acct-1', 'Checking', 0, 0, 1, 0)
                """)
        }

        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    private func makeStore(database: BudgetDatabase) async throws -> (BudgetStore, SyncClient) {
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)
        return (store, syncClient)
    }

    @Test
    func duplicateSingleTransaction() async throws {
        let (database, tempURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        let tx = Transaction(
            id: "tx-orig",
            accountId: "acct-1",
            date: 20260810,
            amount: -1500,
            payeeId: "payee-1",
            payeeName: "Coffee Shop",
            categoryId: "cat-1",
            categoryName: "Dining",
            notes: "Morning latte",
            cleared: true,
            reconciled: true,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: 1000
        )
        try await store.createTransaction(tx)

        await store.duplicateTransaction(tx)

        let all = try await database.fetchTransactions(limit: 1000)
        #expect(all.count == 2)

        let duplicated = all.first { $0.id != "tx-orig" }
        #expect(duplicated != nil)
        #expect(duplicated?.amount == -1500)
        #expect(duplicated?.notes == "Morning latte")
        #expect(duplicated?.cleared == false)
        #expect(duplicated?.reconciled == false)
    }

    @Test
    func duplicateTransactionsAndBulkDelete() async throws {
        let (database, tempURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        let tx1 = Transaction(
            id: "tx-1", accountId: "acct-1", date: 20260810, amount: -1000,
            payeeId: nil, payeeName: "Item 1", categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
        let tx2 = Transaction(
            id: "tx-2", accountId: "acct-1", date: 20260810, amount: -2000,
            payeeId: nil, payeeName: "Item 2", categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 200
        )
        try await store.createTransaction(tx1)
        try await store.createTransaction(tx2)

        // Bulk duplicate
        await store.duplicateTransactions([tx1, tx2])
        let afterDup = try await database.fetchTransactions(limit: 1000)
        #expect(afterDup.count == 4)

        // Bulk delete original 2
        await store.deleteTransactions([tx1, tx2])
        let activeAfterDel = try await database.fetchTransactions(limit: 1000)
        #expect(activeAfterDel.count == 2)
    }

    @Test
    func duplicateTransferTransaction() async throws {
        let (database, tempURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        let source = Transaction(
            id: "tx-source", accountId: "acct-1", date: 20260810, amount: -5000,
            payeeId: "payee-transfer-2", payeeName: "Transfer to Acct 2", categoryId: nil,
            categoryName: nil, notes: "Transfer funds", cleared: true, reconciled: false,
            transferId: "tx-target", isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
        let target = Transaction(
            id: "tx-target", accountId: "acct-2", date: 20260810, amount: 5000,
            payeeId: "payee-transfer-1", payeeName: "Transfer from Acct 1", categoryId: nil,
            categoryName: nil, notes: "Transfer funds", cleared: true, reconciled: false,
            transferId: "tx-source", isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )

        try await store.createTransfer(
            fromAccountId: "acct-1", toAccountId: "acct-2", amountCents: 5000,
            date: 20260810, notes: "Transfer funds", cleared: true
        )

        let initialTxs = try await database.fetchTransactions(limit: 1000)
        #expect(initialTxs.count == 2)
        guard let firstLeg = initialTxs.first else { return }

        // Duplicate the transfer leg
        await store.duplicateTransaction(firstLeg)

        let allTxs = try await database.fetchTransactions(limit: 1000)
        #expect(allTxs.count == 4)

        // Find duplicated pair
        let duplicatedLegs = allTxs.filter { $0.id != initialTxs[0].id && $0.id != initialTxs[1].id }
        #expect(duplicatedLegs.count == 2)
        let dup1 = duplicatedLegs[0]
        let dup2 = duplicatedLegs[1]
        #expect(dup1.transferId == dup2.id)
        #expect(dup2.transferId == dup1.id)
        #expect(dup1.cleared == false)
        #expect(dup2.cleared == false)
    }

    @Test
    func duplicateSplitTransaction() async throws {
        let (database, tempURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        let parent = Transaction(
            id: "parent-1", accountId: "acct-1", date: 20260810, amount: -3000,
            payeeId: "payee-1", payeeName: "Store", categoryId: nil, categoryName: nil,
            notes: "Split purchase", cleared: true, reconciled: false, transferId: nil,
            isParent: true, parentId: nil, tombstone: false, sortOrder: 100
        )
        let child1 = Transaction(
            id: "child-1", accountId: "acct-1", date: 20260810, amount: -2000,
            payeeId: "payee-1", payeeName: "Store", categoryId: "cat-1", categoryName: "Groceries",
            notes: "Food", cleared: true, reconciled: false, transferId: nil,
            isParent: false, parentId: "parent-1", tombstone: false, sortOrder: 100
        )
        let child2 = Transaction(
            id: "child-2", accountId: "acct-1", date: 20260810, amount: -1000,
            payeeId: "payee-1", payeeName: "Store", categoryId: "cat-2", categoryName: "Household",
            notes: "Cleaning", cleared: true, reconciled: false, transferId: nil,
            isParent: false, parentId: "parent-1", tombstone: false, sortOrder: 100
        )

        try await syncClient.createSplit(parent: parent, children: [child1, child2])

        await store.duplicateTransaction(parent)

        let allTxs = try await database.fetchTransactions(limit: 1000)
        let parents = allTxs.filter { $0.isParent }
        #expect(parents.count == 2)

        let duplicatedParent = parents.first { $0.id != "parent-1" }
        #expect(duplicatedParent != nil)
        guard let dupParent = duplicatedParent else { return }

        let duplicatedChildren = try await database.fetchChildTransactions(parentId: dupParent.id)
        #expect(duplicatedChildren.count == 2)
        #expect(duplicatedChildren.contains { $0.amount == -2000 && $0.notes == "Food" })
        #expect(duplicatedChildren.contains { $0.amount == -1000 && $0.notes == "Cleaning" })
    }

    @Test
    func bulkSetClearedStatus() async throws {
        let (database, tempURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        let tx1 = Transaction(
            id: "tx-1", accountId: "acct-1", date: 20260810, amount: -1000,
            payeeId: nil, payeeName: "Item 1", categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
        let tx2 = Transaction(
            id: "tx-2", accountId: "acct-1", date: 20260810, amount: -2000,
            payeeId: nil, payeeName: "Item 2", categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 200
        )
        try await store.createTransaction(tx1)
        try await store.createTransaction(tx2)

        // Mark both cleared
        await store.setClearedStatus(transactions: [tx1, tx2], cleared: true)
        var fetched = try await database.fetchTransactions(limit: 1000)
        #expect(fetched.allSatisfy { $0.cleared == true })

        // Mark both uncleared
        await store.setClearedStatus(transactions: fetched, cleared: false)
        fetched = try await database.fetchTransactions(limit: 1000)
        #expect(fetched.allSatisfy { $0.cleared == false })
    }
}
