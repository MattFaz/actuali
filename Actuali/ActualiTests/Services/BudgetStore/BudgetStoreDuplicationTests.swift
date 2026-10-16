import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreDuplicationTests {
    private func makeDatabase(seedSQL: [String] = []) async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.core + ["""
        INSERT INTO accounts (id, name, offbudget, closed, sort_order, tombstone) VALUES
            ('acct-1', 'Checking', 0, 0, 1, 0),
            ('acct-2', 'Savings', 0, 0, 2, 0);

        INSERT INTO payees (id, name, transfer_acct, tombstone) VALUES
            ('payee-transfer-1', 'Transfer: Checking', 'acct-1', 0),
            ('payee-transfer-2', 'Transfer: Savings', 'acct-2', 0);

        INSERT INTO payee_mapping (id, targetId) VALUES
            ('payee-transfer-1', 'payee-transfer-1'),
            ('payee-transfer-2', 'payee-transfer-2');
        """] + seedSQL)
    }

    /// `fetchTransaction` hides children and tombstones, so it can't answer what
    /// happened to a split line. `Row` can't leave the read closure, so project
    /// the columns this suite asserts on.
    private struct RawRow: Sendable {
        var tombstone = 0
        var transferredId: String?
    }

    private func rawRow(_ database: BudgetDatabase, id: String) async throws -> RawRow? {
        try await database.dbQueueForTesting.read { db in
            try Row.fetchOne(db, sql: "SELECT tombstone, transferred_id FROM transactions WHERE id = ?", arguments: [id])
                .map { RawRow(tombstone: $0["tombstone"] ?? 0, transferredId: $0["transferred_id"]) }
        }
    }

    private func makeStore(database: BudgetDatabase) async throws -> (BudgetStore, SyncClient) {
        let store = BudgetStore.previewInstance()
        let syncClient = try await makeTestSyncClient(database: database)
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
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        let tx = Transaction(
            id: "tx-orig",
            accountId: "acct-1",
            date: 20_260_810,
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
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        let tx1 = Transaction(
            id: "tx-1", accountId: "acct-1", date: 20_260_810, amount: -1000,
            payeeId: nil, payeeName: "Item 1", categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
        let tx2 = Transaction(
            id: "tx-2", accountId: "acct-1", date: 20_260_810, amount: -2000,
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
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        try await store.createTransfer(
            fromAccountId: "acct-1", toAccountId: "acct-2", amountCents: 5000,
            date: 20_260_810, notes: "Transfer funds", cleared: true
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
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        let parent = Transaction(
            id: "parent-1", accountId: "acct-1", date: 20_260_810, amount: -3000,
            payeeId: "payee-1", payeeName: "Store", categoryId: nil, categoryName: nil,
            notes: "Split purchase", cleared: true, reconciled: false, transferId: nil,
            isParent: true, parentId: nil, tombstone: false, sortOrder: 100
        )
        let child1 = Transaction(
            id: "child-1", accountId: "acct-1", date: 20_260_810, amount: -2000,
            payeeId: "payee-1", payeeName: "Store", categoryId: "cat-1", categoryName: "Groceries",
            notes: "Food", cleared: true, reconciled: false, transferId: nil,
            isParent: false, parentId: "parent-1", tombstone: false, sortOrder: 100
        )
        let child2 = Transaction(
            id: "child-2", accountId: "acct-1", date: 20_260_810, amount: -1000,
            payeeId: "payee-1", payeeName: "Store", categoryId: "cat-2", categoryName: "Household",
            notes: "Cleaning", cleared: true, reconciled: false, transferId: nil,
            isParent: false, parentId: "parent-1", tombstone: false, sortOrder: 100
        )

        try await syncClient.createSplit(parent: parent, children: [child1, child2])

        await store.duplicateTransaction(parent)

        let allTxs = try await database.fetchTransactions(limit: 1000)
        let parents = allTxs.filter(\.isParent)
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
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        let tx1 = Transaction(
            id: "tx-1", accountId: "acct-1", date: 20_260_810, amount: -1000,
            payeeId: nil, payeeName: "Item 1", categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
        let tx2 = Transaction(
            id: "tx-2", accountId: "acct-1", date: 20_260_810, amount: -2000,
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
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        try await store.createTransfer(
            fromAccountId: "acct-1", toAccountId: "acct-2", amountCents: 5000,
            date: 20_260_810, notes: "Transfer funds", cleared: true
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
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        // A one-way link: leg A points at B, B points at nothing (upstream
        // files can contain these). Selecting both must not copy B twice.
        let legA = Transaction(
            id: "tx-a", accountId: "acct-1", date: 20_260_810, amount: -5000,
            payeeId: "payee-transfer-2", payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: "tx-b",
            isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
        let legB = Transaction(
            id: "tx-b", accountId: "acct-2", date: 20_260_810, amount: 5000,
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
    func deleteSingleTransferDeletesPartner() async throws {
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        try await store.createTransfer(
            fromAccountId: "acct-1", toAccountId: "acct-2", amountCents: 5000,
            date: 20_260_810, notes: "Transfer funds", cleared: true
        )

        let initialTxs = try await database.fetchTransactions(limit: 1000)
        #expect(initialTxs.count == 2)
        guard let firstLeg = initialTxs.first else { return }

        // Deleting one leg of a transfer deletes the pair: upstream's
        // removeTransfer tombstones the partner, and leaving one leg behind
        // strands a one-sided transfer (GH #724).
        await store.deleteTransaction(firstLeg)

        let activeTxs = try await database.fetchTransactions(limit: 1000)
        #expect(activeTxs.isEmpty)
        #expect(store.error == nil)
    }

    @Test
    func deleteTransferLegWhosePartnerIsAlreadyGone() async throws {
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        // A dangling link — upstream files can contain one. The delete must
        // not fail or resurrect anything.
        let orphan = Transaction(
            id: "tx-orphan", accountId: "acct-1", date: 20_260_810, amount: -5000,
            payeeId: "payee-transfer-2", payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: "tx-missing",
            isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
        try await store.createTransaction(orphan)

        await store.deleteTransaction(orphan)

        let activeTxs = try await database.fetchTransactions(limit: 1000)
        #expect(activeTxs.isEmpty)
        #expect(store.error == nil)
    }

    @Test
    func deleteTransferLegWithinPartnerCycleTerminates() async throws {
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        /// Degenerate data a bad upstream file can carry: the transferId links
        /// form a cycle instead of a pair. Following them must still terminate —
        /// each hop re-reads the row, so the tombstone set in memory doesn't
        /// stop the walk.
        func leg(_ id: String, partner: String) -> Transaction {
            Transaction(
                id: id, accountId: "acct-1", date: 20_260_810, amount: -1000,
                payeeId: "payee-transfer-2", payeeName: nil, categoryId: nil, categoryName: nil,
                notes: nil, cleared: false, reconciled: false, transferId: partner,
                isParent: false, parentId: nil, tombstone: false, sortOrder: 100
            )
        }
        try await syncClient.createTransaction(leg("cycle-a", partner: "cycle-b"), applyRules: false)
        try await syncClient.createTransaction(leg("cycle-b", partner: "cycle-c"), applyRules: false)
        try await syncClient.createTransaction(leg("cycle-c", partner: "cycle-a"), applyRules: false)

        let first = try await database.fetchTransaction(id: "cycle-a")
        #expect(first != nil)
        guard let first else { return }
        await store.deleteTransaction(first)

        let activeTxs = try await database.fetchTransactions(limit: 1000)
        #expect(activeTxs.isEmpty)
    }

    @Test
    func deletingTransferLegUnlinksPartnerThatIsASplitLine() async throws {
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        // The transfer partner is one line of a split in the other account.
        // Tombstoning it would leave the split's parent claiming more than its
        // remaining lines, so the line survives as a plain transaction.
        let partner = Transaction(
            id: "child-transfer", accountId: "acct-2", date: 20_260_810, amount: 4000,
            payeeId: "payee-transfer-1", payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: "leg-out",
            isParent: false, parentId: "split-parent", tombstone: false, sortOrder: 100
        )
        try await syncClient.createSplit(
            parent: Transaction(
                id: "split-parent", accountId: "acct-2", date: 20_260_810, amount: 10000,
                payeeId: nil, payeeName: "Paycheck", categoryId: nil, categoryName: nil,
                notes: nil, cleared: false, reconciled: false, transferId: nil,
                isParent: true, parentId: nil, tombstone: false, sortOrder: 50
            ),
            children: [
                Transaction(
                    id: "child-groceries", accountId: "acct-2", date: 20_260_810, amount: 6000,
                    payeeId: nil, payeeName: "Paycheck", categoryId: nil, categoryName: nil,
                    notes: nil, cleared: false, reconciled: false, transferId: nil,
                    isParent: false, parentId: "split-parent", tombstone: false, sortOrder: 100
                ),
                partner,
            ]
        )
        try await syncClient.createTransaction(
            Transaction(
                id: "leg-out", accountId: "acct-1", date: 20_260_810, amount: -4000,
                payeeId: "payee-transfer-2", payeeName: nil, categoryId: nil, categoryName: nil,
                notes: nil, cleared: false, reconciled: false, transferId: "child-transfer",
                isParent: false, parentId: nil, tombstone: false, sortOrder: 100
            ),
            applyRules: false
        )

        let leg = try #require(try await database.fetchTransaction(id: "leg-out"))
        await store.deleteTransaction(leg)

        #expect(try await rawRow(database, id: "leg-out")?.tombstone == 1)
        // The split line is detached, not deleted: the split stays whole.
        let line = try #require(try await rawRow(database, id: "child-transfer"))
        #expect(line.tombstone == 0)
        #expect(line.transferredId == nil)
        #expect(try await rawRow(database, id: "split-parent")?.tombstone == 0)
        #expect(try await rawRow(database, id: "child-groceries")?.tombstone == 0)
    }

    @Test
    func unlinkingKeepsTheLinesOwnPayee() async throws {
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        // The line is still a line of its split, so detaching it must not blank
        // its payee: that would leave the split with an unnamed line.
        try await syncClient.createSplit(
            parent: Transaction(
                id: "split-parent", accountId: "acct-2", date: 20_260_810, amount: 4000,
                payeeId: nil, payeeName: "Paycheck", categoryId: nil, categoryName: nil,
                notes: nil, cleared: false, reconciled: false, transferId: nil,
                isParent: true, parentId: nil, tombstone: false, sortOrder: 50
            ),
            children: [
                Transaction(
                    id: "child-transfer", accountId: "acct-2", date: 20_260_810, amount: 4000,
                    payeeId: "payee-transfer-1", payeeName: nil, categoryId: nil, categoryName: nil,
                    notes: nil, cleared: false, reconciled: false, transferId: "leg-out",
                    isParent: false, parentId: "split-parent", tombstone: false, sortOrder: 100
                ),
            ]
        )
        try await syncClient.createTransaction(
            Transaction(
                id: "leg-out", accountId: "acct-1", date: 20_260_810, amount: -4000,
                payeeId: "payee-transfer-2", payeeName: nil, categoryId: nil, categoryName: nil,
                notes: nil, cleared: false, reconciled: false, transferId: "child-transfer",
                isParent: false, parentId: nil, tombstone: false, sortOrder: 100
            ),
            applyRules: false
        )

        let leg = try #require(try await database.fetchTransaction(id: "leg-out"))
        await store.deleteTransaction(leg)

        let line = try #require(try await database.fetchTransaction(id: "child-transfer", includingChildren: true))
        #expect(line.transferId == nil)
        #expect(line.payeeId == "payee-transfer-1")
    }

    @Test
    func deletingAParentAndALinkedLegLeavesTheLineDeleted() async throws {
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        // Selecting both the split that owns a transfer line and the line's
        // partner in one batch: the line is both tombstoned (the split goes) and
        // a candidate for unlinking (its partner goes). It must stay deleted —
        // `updateTransactionRow` writes every column, so a later unlink write
        // would put it back.
        try await syncClient.createSplit(
            parent: Transaction(
                id: "split-parent", accountId: "acct-2", date: 20_260_810, amount: 4000,
                payeeId: nil, payeeName: "Paycheck", categoryId: nil, categoryName: nil,
                notes: nil, cleared: false, reconciled: false, transferId: nil,
                isParent: true, parentId: nil, tombstone: false, sortOrder: 50
            ),
            children: [
                Transaction(
                    id: "child-transfer", accountId: "acct-2", date: 20_260_810, amount: 4000,
                    payeeId: "payee-transfer-1", payeeName: nil, categoryId: nil, categoryName: nil,
                    notes: nil, cleared: false, reconciled: false, transferId: "leg-out",
                    isParent: false, parentId: "split-parent", tombstone: false, sortOrder: 100
                ),
            ]
        )
        try await syncClient.createTransaction(
            Transaction(
                id: "leg-out", accountId: "acct-1", date: 20_260_810, amount: -4000,
                payeeId: "payee-transfer-2", payeeName: nil, categoryId: nil, categoryName: nil,
                notes: nil, cleared: false, reconciled: false, transferId: "child-transfer",
                isParent: false, parentId: nil, tombstone: false, sortOrder: 100
            ),
            applyRules: false
        )

        let parent = try #require(try await database.fetchTransaction(id: "split-parent"))
        let leg = try #require(try await database.fetchTransaction(id: "leg-out"))
        await store.deleteTransactions([parent, leg])

        #expect(try await rawRow(database, id: "split-parent")?.tombstone == 1)
        #expect(try await rawRow(database, id: "child-transfer")?.tombstone == 1)
        #expect(try await rawRow(database, id: "leg-out")?.tombstone == 1)
    }

    @Test
    func editingATransferRefusesAPartnerThatIsASplitLine() async throws {
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        // updateTransfer rewrites the partner's account, amount and date. A line
        // of a split must not be dragged out of its split that way, so the edit
        // is refused rather than corrupting the split.
        try await syncClient.createTransaction(
            Transaction(
                id: "child-transfer", accountId: "acct-2", date: 20_260_810, amount: 4000,
                payeeId: "payee-transfer-1", payeeName: nil, categoryId: nil, categoryName: nil,
                notes: nil, cleared: false, reconciled: false, transferId: "leg-out",
                isParent: false, parentId: "split-parent", tombstone: false, sortOrder: 100
            ),
            applyRules: false
        )
        try await syncClient.createTransaction(
            Transaction(
                id: "leg-out", accountId: "acct-1", date: 20_260_810, amount: -4000,
                payeeId: "payee-transfer-2", payeeName: nil, categoryId: nil, categoryName: nil,
                notes: nil, cleared: false, reconciled: false, transferId: "child-transfer",
                isParent: false, parentId: nil, tombstone: false, sortOrder: 100
            ),
            applyRules: false
        )

        let leg = try #require(try await database.fetchTransaction(id: "leg-out"))
        let before = try #require(try await database.fetchTransaction(id: "child-transfer", includingChildren: true))
        await #expect(throws: BudgetStoreError.transferPartnerMissing) {
            try await store.updateTransfer(
                original: leg, fromAccountId: "acct-1", toAccountId: "acct-2",
                amountCents: 9999, date: 20_260_901, notes: "moved", cleared: true, categoryId: nil
            )
        }
        // Refused means refused: the line keeps its account, amount, date and
        // spot in the split.
        let after = try #require(try await database.fetchTransaction(id: "child-transfer", includingChildren: true))
        #expect(after.accountId == before.accountId)
        #expect(after.amount == before.amount)
        #expect(after.date == before.date)
        #expect(after.parentId == "split-parent")
    }

    @Test
    func deletingTransferLegTakesAPartnerSplitWithIt() async throws {
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        // The partner is a whole split. Tombstoning it alone would strand its
        // children behind a parent that no balance query counts.
        try await syncClient.createSplit(
            parent: Transaction(
                id: "partner-parent", accountId: "acct-2", date: 20_260_810, amount: 4000,
                payeeId: nil, payeeName: "Store", categoryId: nil, categoryName: nil,
                notes: nil, cleared: false, reconciled: false, transferId: "leg-out",
                isParent: true, parentId: nil, tombstone: false, sortOrder: 50
            ),
            children: [
                Transaction(
                    id: "partner-child", accountId: "acct-2", date: 20_260_810, amount: 4000,
                    payeeId: nil, payeeName: "Store", categoryId: nil, categoryName: nil,
                    notes: nil, cleared: false, reconciled: false, transferId: nil,
                    isParent: false, parentId: "partner-parent", tombstone: false, sortOrder: 100
                ),
            ]
        )
        try await syncClient.createTransaction(
            Transaction(
                id: "leg-out", accountId: "acct-1", date: 20_260_810, amount: -4000,
                payeeId: "payee-transfer-2", payeeName: nil, categoryId: nil, categoryName: nil,
                notes: nil, cleared: false, reconciled: false, transferId: "partner-parent",
                isParent: false, parentId: nil, tombstone: false, sortOrder: 100
            ),
            applyRules: false
        )

        let leg = try #require(try await database.fetchTransaction(id: "leg-out"))
        await store.deleteTransaction(leg)

        #expect(try await rawRow(database, id: "leg-out")?.tombstone == 1)
        #expect(try await rawRow(database, id: "partner-parent")?.tombstone == 1)
        #expect(try await rawRow(database, id: "partner-child")?.tombstone == 1)
        #expect(try await database.fetchTransactions(limit: 1000).isEmpty)
    }

    @Test
    func bulkDeleteTransferBothLegsSelected() async throws {
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        try await store.createTransfer(
            fromAccountId: "acct-1", toAccountId: "acct-2", amountCents: 5000,
            date: 20_260_810, notes: "Transfer funds", cleared: true
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
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        let parent = Transaction(
            id: "parent-1", accountId: "acct-1", date: 20_260_810, amount: -3000,
            payeeId: "payee-1", payeeName: "Store", categoryId: nil, categoryName: nil,
            notes: "Split purchase", cleared: false, reconciled: false, transferId: nil,
            isParent: true, parentId: nil, tombstone: false, sortOrder: 100
        )
        let child1 = Transaction(
            id: "child-1", accountId: "acct-1", date: 20_260_810, amount: -2000,
            payeeId: "payee-1", payeeName: "Store", categoryId: "cat-1", categoryName: "Groceries",
            notes: "Food", cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: "parent-1", tombstone: false, sortOrder: 99
        )
        let child2 = Transaction(
            id: "child-2", accountId: "acct-1", date: 20_260_810, amount: -1000,
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
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        let reconciledTx = Transaction(
            id: "tx-locked", accountId: "acct-1", date: 20_260_810, amount: -1000,
            payeeId: nil, payeeName: "Locked", categoryId: nil, categoryName: nil,
            notes: nil, cleared: true, reconciled: true, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
        let plainTx = Transaction(
            id: "tx-plain", accountId: "acct-1", date: 20_260_810, amount: -2000,
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
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        // A transfer payee with no partner leg (transferId nil), as upstream
        // files can contain.
        let orphan = Transaction(
            id: "tx-orphan", accountId: "acct-1", date: 20_260_810, amount: -5000,
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
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        let parent = Transaction(
            id: "parent-1", accountId: "acct-1", date: 20_260_810, amount: -3000,
            payeeId: nil, payeeName: "Store", categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: true, parentId: nil, tombstone: false, sortOrder: 100
        )
        // A child that is a transfer leg — its copy loses the partner, so it
        // must lose the transfer payee too.
        let transferChild = Transaction(
            id: "child-1", accountId: "acct-1", date: 20_260_810, amount: -2000,
            payeeId: "payee-transfer-2", payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: "parent-1", tombstone: false, sortOrder: 99
        )
        let plainChild = Transaction(
            id: "child-2", accountId: "acct-1", date: 20_260_810, amount: -1000,
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
        let (database, tempURL) = try await makeDatabase(seedSQL: [TestSchema.rules, """
        INSERT INTO rules (id, stage, conditions_op, conditions, actions, tombstone) VALUES
            ('rule-1', NULL, 'and',
             '[{"op":"contains","field":"imported_description","value":"spam"}]',
             '[{"op":"delete-transaction","value":null}]', 0);
        """])
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        var tx = Transaction(
            id: "tx-ruled", accountId: "acct-1", date: 20_260_810, amount: -1000,
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
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, syncClient) = try await makeStore(database: database)

        let parent = Transaction(
            id: "parent-1", accountId: "acct-1", date: 20_260_810, amount: -3000,
            payeeId: nil, payeeName: "Store", categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: true, parentId: nil, tombstone: false, sortOrder: 100
        )
        let child = Transaction(
            id: "child-1", accountId: "acct-1", date: 20_260_810, amount: -3000,
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
        let (database, tempURL) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (store, _) = try await makeStore(database: database)

        var originalTxs: [Transaction] = []
        for i in 1...5 {
            let tx = Transaction(
                id: "tx-\(i)", accountId: "acct-1", date: 20_260_810, amount: -1000 * i,
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
