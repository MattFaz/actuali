import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreDuplicationTests {

    private func makeDatabase(seedSQL: String = "") throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-dup-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    starting_balance_flag INTEGER DEFAULT 0,
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
                    cat_group TEXT,
                    is_income INTEGER DEFAULT 0,
                    sort_order REAL,
                    hidden INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE category_groups (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    is_income INTEGER DEFAULT 0,
                    sort_order REAL,
                    hidden INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
                );

                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                );

                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0
                );

                INSERT INTO accounts (id, name, offbudget, closed, sort_order, tombstone) VALUES
                    ('acct-1', 'Checking', 0, 0, 1, 0),
                    ('acct-2', 'Savings', 0, 0, 2, 0);

                INSERT INTO payees (id, name, transfer_acct, tombstone) VALUES
                    ('payee-transfer-1', 'Transfer: Checking', 'acct-1', 0),
                    ('payee-transfer-2', 'Transfer: Savings', 'acct-2', 0);

                INSERT INTO payee_mapping (id, targetId) VALUES
                    ('payee-transfer-1', 'payee-transfer-1'),
                    ('payee-transfer-2', 'payee-transfer-2');
                """ + seedSQL)
        }

        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    private func makeStore(database: BudgetDatabase) async throws -> (BudgetStore, SyncClient) {
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)
        store.accounts = [
            Account(id: "acct-1", name: "Checking", type: .checking, offBudget: false, closed: false, sortOrder: 0, balance: 0),
            Account(id: "acct-2", name: "Savings", type: .savings, offBudget: false, closed: false, sortOrder: 1, balance: 0),
        ]
        store.payees = [
            Payee(id: "payee-transfer-1", name: "Transfer: Checking", transferAccountId: "acct-1", tombstone: false),
            Payee(id: "payee-transfer-2", name: "Transfer: Savings", transferAccountId: "acct-2", tombstone: false),
        ]
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

    @Test
    func bulkDuplicateTransferBothLegsSelected() async throws {
        let (database, tempURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        try await store.createTransfer(
            fromAccountId: "acct-1", toAccountId: "acct-2", amountCents: 5000,
            date: 20260810, notes: "Transfer funds", cleared: true
        )

        let initialTxs = try await database.fetchTransactions(limit: 1000)
        #expect(initialTxs.count == 2)

        // Bulk duplicate passing both legs of the transfer
        await store.duplicateTransactions(initialTxs)

        let allTxs = try await database.fetchTransactions(limit: 1000)
        // Should only create 1 new transfer pair (total 4 transactions)
        #expect(allTxs.count == 4)

        let duplicatedLegs = allTxs.filter { $0.id != initialTxs[0].id && $0.id != initialTxs[1].id }
        #expect(duplicatedLegs.count == 2)
        let dup1 = duplicatedLegs[0]
        let dup2 = duplicatedLegs[1]
        #expect(dup1.transferId == dup2.id)
        #expect(dup2.transferId == dup1.id)
    }

    @Test
    func bulkDuplicateHalfLinkedTransferCopiesPartnerOnce() async throws {
        let (database, tempURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        // A one-way link: leg A points at B, B points at nothing (upstream
        // files can contain these). Selecting both must not copy B twice.
        let legA = Transaction(
            id: "tx-a", accountId: "acct-1", date: 20260810, amount: -5000,
            payeeId: "payee-transfer-2", payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: "tx-b",
            isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
        let legB = Transaction(
            id: "tx-b", accountId: "acct-2", date: 20260810, amount: 5000,
            payeeId: "payee-transfer-1", payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
        try await syncClient.createTransaction(legA, applyRules: false)
        try await syncClient.createTransaction(legB, applyRules: false)

        await store.duplicateTransactions([legA, legB])

        // One new pair only: A's duplication copies both legs, B is skipped.
        let all = try await database.fetchTransactions(limit: 1000)
        #expect(all.count == 4)
    }

    @Test
    func deleteSingleTransferDoesNotDeletePartner() async throws {
        let (database, tempURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        try await store.createTransfer(
            fromAccountId: "acct-1", toAccountId: "acct-2", amountCents: 5000,
            date: 20260810, notes: "Transfer funds", cleared: true
        )

        let initialTxs = try await database.fetchTransactions(limit: 1000)
        #expect(initialTxs.count == 2)
        guard let firstLeg = initialTxs.first else { return }

        // Deleting a single leg via deleteTransaction must not delete the partner leg
        await store.deleteTransaction(firstLeg)

        let activeTxs = try await database.fetchTransactions(limit: 1000)
        #expect(activeTxs.count == 1)
        #expect(activeTxs.first?.id != firstLeg.id)
    }

    @Test
    func bulkDeleteTransferBothLegsSelected() async throws {
        let (database, tempURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        try await store.createTransfer(
            fromAccountId: "acct-1", toAccountId: "acct-2", amountCents: 5000,
            date: 20260810, notes: "Transfer funds", cleared: true
        )

        let initialTxs = try await database.fetchTransactions(limit: 1000)
        #expect(initialTxs.count == 2)

        // Bulk delete passing both legs of the transfer
        await store.deleteTransactions(initialTxs)

        let remainingTxs = try await database.fetchTransactions(limit: 1000)
        #expect(remainingTxs.isEmpty)
        #expect(store.error == nil)
    }

    @Test
    func bulkSetClearedStatusSplitParent() async throws {
        let (database, tempURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        let parent = Transaction(
            id: "parent-1", accountId: "acct-1", date: 20260810, amount: -3000,
            payeeId: "payee-1", payeeName: "Store", categoryId: nil, categoryName: nil,
            notes: "Split purchase", cleared: false, reconciled: false, transferId: nil,
            isParent: true, parentId: nil, tombstone: false, sortOrder: 100
        )
        let child1 = Transaction(
            id: "child-1", accountId: "acct-1", date: 20260810, amount: -2000,
            payeeId: "payee-1", payeeName: "Store", categoryId: "cat-1", categoryName: "Groceries",
            notes: "Food", cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: "parent-1", tombstone: false, sortOrder: 99
        )
        let child2 = Transaction(
            id: "child-2", accountId: "acct-1", date: 20260810, amount: -1000,
            payeeId: "payee-1", payeeName: "Store", categoryId: "cat-2", categoryName: "Household",
            notes: "Cleaning", cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: "parent-1", tombstone: false, sortOrder: 98
        )

        try await syncClient.createSplit(parent: parent, children: [child1, child2])

        // Bulk mark parent cleared
        await store.setClearedStatus(transactions: [parent], cleared: true)

        var children = try await database.fetchChildTransactions(parentId: "parent-1")
        #expect(children.count == 2)
        #expect(children.allSatisfy { $0.cleared == true })

        // Bulk mark parent uncleared
        var updatedParent = parent
        updatedParent.cleared = true
        await store.setClearedStatus(transactions: [updatedParent], cleared: false)

        children = try await database.fetchChildTransactions(parentId: "parent-1")
        #expect(children.count == 2)
        #expect(children.allSatisfy { $0.cleared == false })
    }

    @Test
    func bulkUnclearLeavesReconciledRowsLocked() async throws {
        let (database, tempURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        let reconciledTx = Transaction(
            id: "tx-locked", accountId: "acct-1", date: 20260810, amount: -1000,
            payeeId: nil, payeeName: "Locked", categoryId: nil, categoryName: nil,
            notes: nil, cleared: true, reconciled: true, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
        let plainTx = Transaction(
            id: "tx-plain", accountId: "acct-1", date: 20260810, amount: -2000,
            payeeId: nil, payeeName: "Plain", categoryId: nil, categoryName: nil,
            notes: nil, cleared: true, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 200
        )
        try await store.createTransaction(reconciledTx)
        try await store.createTransaction(plainTx)

        await store.setClearedStatus(transactions: [reconciledTx, plainTx], cleared: false)

        let fetched = try await database.fetchTransactions(limit: 1000)
        let locked = fetched.first { $0.id == "tx-locked" }
        #expect(locked?.reconciled == true)
        #expect(locked?.cleared == true)
        #expect(fetched.first { $0.id == "tx-plain" }?.cleared == false)
    }

    @Test
    func duplicateOrphanTransferPayeeClearsPayee() async throws {
        let (database, tempURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        // A transfer payee with no partner leg (transferId nil), as upstream
        // files can contain.
        let orphan = Transaction(
            id: "tx-orphan", accountId: "acct-1", date: 20260810, amount: -5000,
            payeeId: "payee-transfer-2", payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
        try await store.createTransaction(orphan)

        // Duplicate the row as fetched, so transferAcct is populated the way
        // list rows have it.
        let fetched = try await database.fetchTransaction(id: "tx-orphan")
        #expect(fetched?.transferAcct == "acct-2")
        await store.duplicateTransaction(fetched!)

        let all = try await database.fetchTransactions(limit: 1000)
        #expect(all.count == 2)
        let copy = all.first { $0.id != "tx-orphan" }
        #expect(copy?.payeeId == nil)
    }

    @Test
    func duplicateSplitWithTransferChildClearsChildPayee() async throws {
        let (database, tempURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        let parent = Transaction(
            id: "parent-1", accountId: "acct-1", date: 20260810, amount: -3000,
            payeeId: nil, payeeName: "Store", categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: true, parentId: nil, tombstone: false, sortOrder: 100
        )
        // A child that is a transfer leg — its copy loses the partner, so it
        // must lose the transfer payee too.
        let transferChild = Transaction(
            id: "child-1", accountId: "acct-1", date: 20260810, amount: -2000,
            payeeId: "payee-transfer-2", payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: "parent-1", tombstone: false, sortOrder: 99
        )
        let plainChild = Transaction(
            id: "child-2", accountId: "acct-1", date: 20260810, amount: -1000,
            payeeId: nil, payeeName: "Plain", categoryId: "cat-1", categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: "parent-1", tombstone: false, sortOrder: 98
        )
        try await syncClient.createSplit(parent: parent, children: [transferChild, plainChild])

        await store.duplicateTransaction(parent)

        let dupParent = try await database.fetchTransactions(limit: 1000)
            .first { $0.isParent && $0.id != "parent-1" }
        #expect(dupParent != nil)
        let dupChildren = try await database.fetchChildTransactions(parentId: dupParent?.id ?? "")
        #expect(dupChildren.count == 2)
        #expect(dupChildren.first { $0.amount == -2000 }?.payeeId == nil)
    }

    @Test
    func duplicateSkipsRulesEngine() async throws {
        // A delete-transaction rule that matches the source row must not be
        // able to silently swallow (or rewrite) the copy.
        let (database, tempURL) = try makeDatabase(seedSQL: """

            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                stage TEXT,
                conditions_op TEXT DEFAULT 'and',
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER DEFAULT 0
            );

            INSERT INTO rules (id, stage, conditions_op, conditions, actions, tombstone) VALUES
                ('rule-1', NULL, 'and',
                 '[{"op":"contains","field":"imported_description","value":"spam"}]',
                 '[{"op":"delete-transaction","value":null}]', 0);
            """)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        var tx = Transaction(
            id: "tx-ruled", accountId: "acct-1", date: 20260810, amount: -1000,
            payeeId: nil, payeeName: "Spam Co", categoryId: nil, categoryName: nil,
            notes: "keep me", cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
        tx.importedPayee = "SPAM CO"
        try await syncClient.createTransaction(tx, applyRules: false)

        await store.duplicateTransaction(tx)

        let all = try await database.fetchTransactions(limit: 1000)
        #expect(all.count == 2)
        #expect(store.error == nil)
        let copy = all.first { $0.id != "tx-ruled" }
        #expect(copy?.notes == "keep me")
    }

    @Test
    func bulkDeleteSplitParentDeletesChildren() async throws {
        let (database, tempURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        let parent = Transaction(
            id: "parent-1", accountId: "acct-1", date: 20260810, amount: -3000,
            payeeId: nil, payeeName: "Store", categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: true, parentId: nil, tombstone: false, sortOrder: 100
        )
        let child = Transaction(
            id: "child-1", accountId: "acct-1", date: 20260810, amount: -3000,
            payeeId: nil, payeeName: "Store", categoryId: "cat-1", categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: "parent-1", tombstone: false, sortOrder: 99
        )
        try await syncClient.createSplit(parent: parent, children: [child])

        await store.deleteTransactions([parent])

        let remaining = try await database.fetchTransactions(limit: 1000)
        #expect(remaining.isEmpty)
        let children = try await database.fetchChildTransactions(parentId: "parent-1")
        #expect(children.isEmpty)
    }

    @Test
    func bulkDuplicateSortOrderDifferentiation() async throws {
        let (database, tempURL) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        var originalTxs: [Transaction] = []
        for i in 1...5 {
            let tx = Transaction(
                id: "tx-\(i)", accountId: "acct-1", date: 20260810, amount: -1000 * i,
                payeeId: nil, payeeName: "Item \(i)", categoryId: nil, categoryName: nil,
                notes: nil, cleared: false, reconciled: false, transferId: nil,
                isParent: false, parentId: nil, tombstone: false, sortOrder: Double(i * 100)
            )
            try await store.createTransaction(tx)
            originalTxs.append(tx)
        }

        await store.duplicateTransactions(originalTxs)

        let allTxs = try await database.fetchTransactions(limit: 1000)
        #expect(allTxs.count == 10)

        let duplicates = allTxs.filter { !originalTxs.map(\.id).contains($0.id) }
        #expect(duplicates.count == 5)

        let sortOrders = duplicates.compactMap(\.sortOrder)
        #expect(sortOrders.count == 5)
        #expect(Set(sortOrders).count == 5)
    }
}
