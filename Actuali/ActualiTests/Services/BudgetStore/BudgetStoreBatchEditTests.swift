import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreBatchEditTests {
    private func makeStore() async throws -> (BudgetStore, BudgetDatabase, URL) {
        let (database, tempURL) = try await makeTestDatabase(TestSchema.core + ["""
        INSERT INTO accounts (id, name, offbudget, closed, sort_order, tombstone) VALUES
            ('acct-1', 'Checking', 0, 0, 1, 0),
            ('acct-2', 'Savings', 0, 0, 2, 0);

        INSERT INTO payees (id, name, transfer_acct, tombstone) VALUES
            ('payee-transfer-1', 'Transfer: Checking', 'acct-1', 0),
            ('payee-transfer-2', 'Transfer: Savings', 'acct-2', 0);

        INSERT INTO payee_mapping (id, targetId) VALUES
            ('payee-transfer-1', 'payee-transfer-1'),
            ('payee-transfer-2', 'payee-transfer-2');
        """])
        let store = BudgetStore.previewInstance()
        let syncClient = try await makeTestSyncClient(database: database)
        store.configureForTesting(database: database, syncClient: syncClient)
        return (store, database, tempURL)
    }

    private func transaction(
        _ id: String, amount: Int = -1000, notes: String? = nil,
        categoryId: String? = nil, reconciled: Bool = false
    ) -> Transaction {
        Transaction(
            id: id, accountId: "acct-1", date: 20_260_810, amount: amount,
            payeeId: nil, payeeName: nil, categoryId: categoryId, categoryName: nil,
            notes: notes, cleared: false, reconciled: reconciled, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
    }

    private func stored(_ database: BudgetDatabase, _ id: String) async throws -> Transaction? {
        try await database.fetchTransactions(limit: 1000).first { $0.id == id }
    }

    @Test
    func totalIsTheNetAmountOfTheSelection() {
        let selection = [transaction("a", amount: -2500), transaction("b", amount: 1000), transaction("c", amount: -300)]
        #expect(TransactionBulkEdit.total(of: selection) == -1800)
        #expect(TransactionBulkEdit.total(of: []) == 0)
    }

    @Test
    func addingATagAppendsItToTheNote() {
        #expect(TransactionBulkEdit.notes(adding: "trip", to: nil) == "#trip")
        #expect(TransactionBulkEdit.notes(adding: "#trip", to: "  ") == "#trip")
        #expect(TransactionBulkEdit.notes(adding: "trip", to: "Hotel #food") == "Hotel #food #trip")
    }

    @Test
    func addingATagSkipsNotesThatAlreadyHaveIt() {
        #expect(TransactionBulkEdit.notes(adding: "trip", to: "Hotel #Trip") == nil)
        #expect(TransactionBulkEdit.notes(adding: "trip", to: "#trip") == nil)
        // A longer tag that merely starts with the same letters is a different tag.
        #expect(TransactionBulkEdit.notes(adding: "trip", to: "#trips") == "#trips #trip")
        #expect(TransactionBulkEdit.notes(adding: "two words", to: "x") == nil)
    }

    @Test
    func setCategoryAppliesToEverySelectedTransaction() async throws {
        let (store, database, tempURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let a = transaction("tx-a"), b = transaction("tx-b", categoryId: "cat-old")
        try await store.createTransaction(a)
        try await store.createTransaction(b)

        await store.setCategory("cat-new", for: [a, b])

        #expect(try await stored(database, "tx-a")?.categoryId == "cat-new")
        #expect(try await stored(database, "tx-b")?.categoryId == "cat-new")
        #expect(store.error == nil)
    }

    @Test
    func setCategoryLeavesReconciledAndTransferRowsAlone() async throws {
        let (store, database, tempURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let open = transaction("tx-open")
        let locked = transaction("tx-locked", reconciled: true)
        try await store.createTransaction(open)
        try await store.createTransaction(locked)
        try await store.createTransfer(
            fromAccountId: "acct-1", toAccountId: "acct-2", amountCents: 5000,
            date: 20_260_810, notes: nil, cleared: false
        )
        let transferLeg = try await database.fetchTransactions(limit: 1000).first { $0.transferId != nil }
        let leg = try #require(transferLeg)

        await store.setCategory("cat-new", for: [open, locked, leg])

        #expect(try await stored(database, "tx-open")?.categoryId == "cat-new")
        #expect(try await stored(database, "tx-locked")?.categoryId == nil)
        #expect(try await stored(database, leg.id)?.categoryId == nil)
        #expect(store.error?.isEmpty == false, "the skipped rows are reported")
    }

    @Test
    func addTagWritesItIntoEachNoteOnce() async throws {
        let (store, database, tempURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let plain = transaction("tx-plain")
        let noted = transaction("tx-noted", notes: "Hotel #food")
        let already = transaction("tx-already", notes: "Flight #trip")
        for tx in [plain, noted, already] {
            try await store.createTransaction(tx)
        }

        await store.addTag("trip", to: [plain, noted, already])

        #expect(try await stored(database, "tx-plain")?.notes == "#trip")
        #expect(try await stored(database, "tx-noted")?.notes == "Hotel #food #trip")
        #expect(try await stored(database, "tx-already")?.notes == "Flight #trip")
    }

    @Test
    func addTagRejectsInvalidNamesAndLeavesReconciledRowsAlone() async throws {
        let (store, database, tempURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let open = transaction("tx-open")
        let locked = transaction("tx-locked", reconciled: true)
        try await store.createTransaction(open)
        try await store.createTransaction(locked)

        await store.addTag("two words", to: [open])
        #expect(try await stored(database, "tx-open")?.notes == nil)

        await store.addTag("trip", to: [open, locked])
        #expect(try await stored(database, "tx-open")?.notes == "#trip")
        #expect(try await stored(database, "tx-locked")?.notes == nil)
        #expect(store.error?.isEmpty == false, "the locked row is reported")
    }

    // MARK: - Merge

    private func mergeable(
        _ id: String, date: Int = 20_260_810, payeeId: String? = nil, notes: String? = nil,
        categoryId: String? = nil, cleared: Bool = false, imported: String? = nil, financialId: String? = nil
    ) -> Transaction {
        var tx = Transaction(
            id: id, accountId: "acct-1", date: date, amount: -4200,
            payeeId: payeeId, payeeName: nil, categoryId: categoryId, categoryName: nil,
            notes: notes, cleared: cleared, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
        tx.importedPayee = imported
        tx.financialId = financialId
        return tx
    }

    @Test
    func mergeRequiresSameAccountSameAmountAndNoTransfers() {
        let a = mergeable("a")
        var otherAccount = mergeable("b")
        otherAccount.accountId = "acct-2"
        var otherAmount = mergeable("c")
        otherAmount.amount = -100
        var transfer = mergeable("d")
        transfer.transferId = "other-leg"

        #expect(TransactionBulkEdit.canMerge(a, mergeable("b")))
        #expect(!TransactionBulkEdit.canMerge(a, a))
        #expect(!TransactionBulkEdit.canMerge(a, otherAccount))
        #expect(!TransactionBulkEdit.canMerge(a, otherAmount))
        #expect(!TransactionBulkEdit.canMerge(a, transfer))
    }

    @Test
    func mergeKeepsTheImportedThenTheOneWithAnImportedPayeeThenTheEarlier() {
        let early = mergeable("early", date: 20_260_801)
        let late = mergeable("late", date: 20_260_809)
        #expect(TransactionBulkEdit.keepAndDrop(early, late, importedIds: []).keep.id == "early")
        #expect(TransactionBulkEdit.keepAndDrop(late, early, importedIds: []).keep.id == "early")
        #expect(TransactionBulkEdit.keepAndDrop(early, late, importedIds: ["late"]).keep.id == "late")
        let withPayee = mergeable("late", date: 20_260_809, imported: "COFFEE #12")
        #expect(TransactionBulkEdit.keepAndDrop(early, withPayee, importedIds: []).keep.id == "late")
    }

    @Test
    func mergeFillsBlanksFromTheDroppedTransaction() {
        let keep = mergeable("keep", payeeId: nil, notes: "", categoryId: nil, cleared: false)
        let drop = mergeable("drop", payeeId: "p-1", notes: "Lunch #food", categoryId: "cat-1", cleared: true)
        let merged = TransactionBulkEdit.merged(keep: keep, drop: drop)
        #expect(merged.payeeId == "p-1")
        #expect(merged.notes == "Lunch #food")
        #expect(merged.categoryId == "cat-1")
        #expect(merged.cleared)

        let full = mergeable("full", payeeId: "p-2", notes: "Mine", categoryId: "cat-2")
        let kept = TransactionBulkEdit.merged(keep: full, drop: drop)
        #expect(kept.payeeId == "p-2")
        #expect(kept.notes == "Mine")
        #expect(kept.categoryId == "cat-2")
    }

    @Test
    func mergeKeepsOneTransactionWithTheCombinedFieldsAndDeletesTheOther() async throws {
        let (store, database, tempURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let imported = mergeable("imported", date: 20_260_809, financialId: "bank-1")
        let manual = mergeable("manual", date: 20_260_801, notes: "Dinner #out", categoryId: "cat-food", cleared: true)
        try await store.createTransaction(imported)
        try await store.createTransaction(manual)

        await store.mergeTransactions(manual, imported)

        let all = try await database.fetchTransactions(limit: 1000)
        #expect(all.map(\.id) == ["imported"], "the imported row survives and the manual one is gone")
        let kept = try #require(all.first)
        #expect(kept.notes == "Dinner #out")
        #expect(kept.categoryId == "cat-food")
        #expect(kept.cleared)
        #expect(store.error == nil)
    }

    @Test
    func mergeMovesTheSplitOfTheDroppedTransactionToTheKeptOne() async throws {
        let (store, database, tempURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let keep = mergeable("keep", date: 20_260_801)
        var parent = mergeable("parent", date: 20_260_809)
        parent.isParent = true
        var childA = mergeable("child-a", categoryId: "cat-a")
        childA.amount = -2000
        childA.parentId = "parent"
        var childB = mergeable("child-b", categoryId: "cat-b")
        childB.amount = -2200
        childB.parentId = "parent"
        try await store.createTransaction(keep)
        try await store.createTransaction(parent)
        try await store.createTransaction(childA)
        try await store.createTransaction(childB)

        await store.mergeTransactions(keep, parent)

        let kept = try #require(try await stored(database, "keep"))
        #expect(kept.isParent)
        #expect(kept.categoryId == nil)
        let children = try await database.fetchChildTransactions(parentId: "keep")
        #expect(Set(children.map(\.id)) == ["child-a", "child-b"])
        #expect(try await stored(database, "parent") == nil)
    }
}
