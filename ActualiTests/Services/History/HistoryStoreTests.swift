import Foundation
import Testing

@MainActor
struct HistoryStoreTests {
    private func transaction(
        id: String,
        amount: Int = -1000,
        isParent: Bool = false,
        parentId: String? = nil
    ) -> Transaction {
        Transaction(
            id: id,
            accountId: "account",
            date: 20260906,
            amount: amount,
            payeeId: "payee",
            payeeName: "Groceries",
            categoryId: isParent ? nil : "category",
            categoryName: isParent ? nil : "Food",
            notes: nil,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: isParent,
            parentId: parentId,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )
    }

    @Test func retainsNewest10Actions() {
        let suite = "HistoryStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HistoryStore(defaults: defaults)

        for index in 0..<11 {
            store.record(
                budgetID: "budget",
                kind: .created,
                before: [],
                after: [transaction(id: "\(index)")]
            )
        }

        #expect(store.actions.count == 10)
        #expect(store.actions.allSatisfy { $0.status == .applied })
        #expect(store.actions.allSatisfy { $0.after.count == 1 })
        #expect(store.actions.contains { $0.after.first?.id == "0" } == false)
        #expect(store.actions.contains { $0.after.first?.id == "10" })
    }

    @Test func actionsPersistAndReload() {
        let suite = "HistoryStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = HistoryStore(defaults: defaults)
        first.record(
            budgetID: "budget",
            kind: .created,
            before: [],
            after: [transaction(id: "persisted")]
        )

        let second = HistoryStore(defaults: defaults)
        second.load(budgetID: "budget")
        #expect(second.actions.count == 1)
        #expect(second.actions.first?.after.first?.id == "persisted")
    }

    @Test func historyIsIsolatedPerBudget() {
        let suite = "HistoryStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HistoryStore(defaults: defaults)

        store.record(
            budgetID: "budget-a",
            kind: .created,
            before: [],
            after: [transaction(id: "a")]
        )
        store.record(
            budgetID: "budget-b",
            kind: .created,
            before: [],
            after: [transaction(id: "b")]
        )

        store.load(budgetID: "budget-a")
        #expect(store.actions.count == 1)
        #expect(store.actions[0].budgetID == "budget-a")
        #expect(store.actions[0].after.first?.id == "a")

        store.load(budgetID: "budget-b")
        #expect(store.actions.count == 1)
        #expect(store.actions[0].budgetID == "budget-b")
        #expect(store.actions[0].after.first?.id == "b")

        let reloaded = HistoryStore(defaults: defaults)
        reloaded.load(budgetID: "budget-b")
        #expect(reloaded.actions.count == 1)
        #expect(reloaded.actions[0].budgetID == "budget-b")
        #expect(reloaded.actions[0].after.first?.id == "b")
    }

    @Test func actionsWithWrongBudgetAreDiscardedOnLoad() {
        let suite = "HistoryStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let wrongBudget = HistoryAction(
            id: "wrong",
            createdAt: Date(),
            budgetID: "budget-b",
            kind: .created,
            before: [],
            after: [HistoryTransactionSnapshot(transaction(id: "b"))],
            status: .applied
        )
        let rightBudget = HistoryAction(
            id: "right",
            createdAt: Date().addingTimeInterval(-1),
            budgetID: "budget-a",
            kind: .created,
            before: [],
            after: [HistoryTransactionSnapshot(transaction(id: "a"))],
            status: .applied
        )
        defaults.set(try! JSONEncoder().encode([wrongBudget, rightBudget]), forKey: "history.actions.budget-a")

        let store = HistoryStore(defaults: defaults)
        store.load(budgetID: "budget-a")
        #expect(store.actions.count == 1)
        #expect(store.actions[0].budgetID == "budget-a")
        #expect(store.actions[0].after.first?.id == "a")
    }

    @Test func recordsFullSplitSnapshots() {
        let suite = "HistoryStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HistoryStore(defaults: defaults)

        let oldParent = transaction(id: "parent", isParent: true)
        let oldChild = transaction(id: "child", amount: -400, parentId: "parent")
        let newParent = transaction(id: "parent", amount: -1200, isParent: true)
        let newChild = transaction(id: "child", amount: -700, parentId: "parent")
        let addedChild = transaction(id: "added", amount: -500, parentId: "parent")

        var absentAddedChild = HistoryTransactionSnapshot(addedChild)
        absentAddedChild.tombstone = true
        var removedChild = HistoryTransactionSnapshot(oldChild)
        removedChild.tombstone = true

        store.recordSnapshots(
            budgetID: "budget",
            kind: .edited,
            before: [
                HistoryTransactionSnapshot(oldParent),
                HistoryTransactionSnapshot(oldChild),
                absentAddedChild
            ],
            after: [
                HistoryTransactionSnapshot(newParent),
                HistoryTransactionSnapshot(newChild),
                HistoryTransactionSnapshot(removedChild)
            ]
        )

        let action = store.actions[0]
        #expect(action.before.contains { $0.id == "child" && !$0.tombstone })
        #expect(action.before.contains { $0.id == "added" && $0.tombstone })
        #expect(action.after.contains { $0.id == "added" && !$0.tombstone })
        #expect(action.after.contains { $0.id == "child" && $0.tombstone })
    }

    @Test func splitTitleRecognizesCollapseFromBeforeState() {
        let parent = HistoryTransactionSnapshot(transaction(id: "parent", isParent: true))
        let collapsed = HistoryTransactionSnapshot(transaction(id: "parent"))
        let action = HistoryAction(
            id: "collapse",
            createdAt: Date(),
            budgetID: "budget",
            kind: .edited,
            before: [parent],
            after: [collapsed],
            status: .applied
        )

        #expect(action.title == "Edited split transaction")
    }

    @Test func deletedActionsRepresentAbsentRowsAfterDeletion() {
        let source = transaction(id: "source")
        var tombstone = HistoryTransactionSnapshot(source)
        tombstone.tombstone = true
        let action = HistoryAction(
            id: "deleted",
            createdAt: Date(),
            budgetID: "budget",
            kind: .deleted,
            before: [HistoryTransactionSnapshot(source)],
            after: [tombstone],
            status: .applied
        )

        #expect(action.after[0].tombstone)
        #expect(action.before[0].tombstone == false)
    }

    @Test func undoneActionsCannotBeUndone() {
        let suite = "HistoryStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let action = HistoryAction(
            id: "undone",
            createdAt: Date(),
            budgetID: "budget",
            kind: .edited,
            before: [],
            after: [HistoryTransactionSnapshot(transaction(id: "tx"))],
            status: .undone
        )

        let store = HistoryStore(defaults: defaults)
        store.load(budgetID: "budget")
        #expect(store.canUndo(action) == false)
    }

    @Test func liveSnapshotComparisonIgnoresUnstableReadOnlyFields() {
        var recorded = HistoryTransactionSnapshot(transaction(id: "tx"))
        recorded.sortOrder = 123.0
        recorded.financialId = "wallet-id"
        recorded.startingBalanceFlag = true
        recorded.payeeName = "Old Display Name"
        recorded.categoryName = "Old Category Name"

        var fetched = transaction(id: "tx")
        fetched.sortOrder = 456.0
        fetched.financialId = nil
        fetched.startingBalanceFlag = false
        fetched.payeeName = "New Display Name"
        fetched.categoryName = "New Category Name"

        #expect(recorded.matchesLiveTransaction(fetched))
    }

    @Test func liveSnapshotComparisonDetectsUndoRelevantChanges() {
        let base = HistoryTransactionSnapshot(transaction(id: "tx"))
        let mutators: [(HistoryTransactionSnapshot) -> Void] = [
            { $0.accountId = "other-account" },
            { $0.date += 1 },
            { $0.amount -= 1 },
            { $0.payeeId = "other-payee" },
            { $0.categoryId = "other-category" },
            { $0.notes = "changed" },
            { $0.cleared = true },
            { $0.reconciled = true },
            { $0.transferId = "other-transfer" },
            { $0.isParent = true },
            { $0.parentId = "parent" },
            { $0.tombstone = true },
            { $0.importedPayee = "imported" },
            { $0.schedule = "schedule" }
        ]

        for mutate in mutators {
            var changed = base
            mutate(&changed)
            #expect(changed.matchesLiveTransaction(base.transaction()) == false)
        }
    }

    @Test func coalescesSplitEditPublicationsForSameParent() {
        let suite = "HistoryStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HistoryStore(defaults: defaults)

        let oldParent = transaction(id: "parent", isParent: true)
        let newParent = transaction(id: "parent", amount: -1200, isParent: true)
        let oldChild = transaction(id: "child", amount: -400, parentId: "parent")
        let newChild = transaction(id: "child", amount: -700, parentId: "parent")

        store.recordSnapshots(
            budgetID: "budget",
            kind: .edited,
            before: [HistoryTransactionSnapshot(oldParent)],
            after: [HistoryTransactionSnapshot(newParent)]
        )
        store.recordSnapshots(
            budgetID: "budget",
            kind: .edited,
            before: [HistoryTransactionSnapshot(newParent), HistoryTransactionSnapshot(oldChild)],
            after: [HistoryTransactionSnapshot(newParent), HistoryTransactionSnapshot(newChild)]
        )

        #expect(store.actions.count == 1)
        #expect(store.actions[0].before.map(\.id) == ["parent", "child"])
        #expect(store.actions[0].after.map(\.id) == ["parent", "child"])
        #expect(store.actions[0].before.first?.amount == oldParent.amount)
        #expect(store.actions[0].after.first?.amount == newParent.amount)
        #expect(store.actions[0].before.last?.amount == oldChild.amount)
        #expect(store.actions[0].after.last?.amount == newChild.amount)
    }

    @Test func transferAndSplitDeletionTitlesAreExplicit() {
        let source = transaction(id: "source")
        let target = transaction(id: "target")

        var transferSource = HistoryTransactionSnapshot(source)
        var transferTarget = HistoryTransactionSnapshot(target)
        transferSource.transferId = target.id
        transferTarget.transferId = source.id
        transferSource.tombstone = true
        transferTarget.tombstone = true
        let deletedTransfer = HistoryAction(
            id: "transfer",
            createdAt: Date(),
            budgetID: "budget",
            kind: .deleted,
            before: [HistoryTransactionSnapshot(source), HistoryTransactionSnapshot(target)],
            after: [transferSource, transferTarget],
            status: .applied
        )
        #expect(deletedTransfer.title == "Deleted transfer")

        var splitParent = HistoryTransactionSnapshot(source)
        splitParent.isParent = true
        splitParent.tombstone = true
        let deletedSplit = HistoryAction(
            id: "split",
            createdAt: Date(),
            budgetID: "budget",
            kind: .deleted,
            before: [HistoryTransactionSnapshot(source)],
            after: [splitParent],
            status: .applied
        )
        #expect(deletedSplit.title == "Deleted split transaction")
    }

    @Test func coalescesTransferLegsIntoOneHistoryAction() {
        let suite = "HistoryStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HistoryStore(defaults: defaults)

        let source = transaction(id: "source", amount: -5000)
        let target = transaction(id: "target", amount: 5000)
        var sourceSnapshot = HistoryTransactionSnapshot(source)
        var targetSnapshot = HistoryTransactionSnapshot(target)
        sourceSnapshot.transferId = target.id
        targetSnapshot.transferId = source.id

        store.recordSnapshots(
            budgetID: "budget",
            kind: .created,
            before: [],
            after: [sourceSnapshot]
        )
        store.recordSnapshots(
            budgetID: "budget",
            kind: .created,
            before: [],
            after: [targetSnapshot]
        )

        #expect(store.actions.count == 1)
        #expect(store.actions[0].after.count == 2)
        #expect(store.actions[0].after.contains { $0.id == source.id })
        #expect(store.actions[0].after.contains { $0.id == target.id })
        #expect(store.actions[0].title == "Created transfer")
    }

    @Test func doesNotCoalesceUnrelatedTransferLegs() {
        let suite = "HistoryStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HistoryStore(defaults: defaults)

        let first = transaction(id: "first")
        let unrelated = transaction(id: "unrelated")
        let delayedPartner = transaction(id: "partner")
        var firstSnapshot = HistoryTransactionSnapshot(first)
        var partnerSnapshot = HistoryTransactionSnapshot(delayedPartner)
        firstSnapshot.transferId = delayedPartner.id
        partnerSnapshot.transferId = first.id

        store.recordSnapshots(
            budgetID: "budget",
            kind: .created,
            before: [],
            after: [firstSnapshot]
        )
        store.record(
            budgetID: "budget",
            kind: .created,
            before: [],
            after: [unrelated]
        )
        store.recordSnapshots(
            budgetID: "budget",
            kind: .created,
            before: [],
            after: [partnerSnapshot]
        )

        #expect(store.actions.count == 3)
        #expect(store.actions[0].after.first?.id == delayedPartner.id)
        #expect(store.actions[1].after.first?.id == unrelated.id)
        #expect(store.actions[2].after.first?.id == first.id)
    }
}
