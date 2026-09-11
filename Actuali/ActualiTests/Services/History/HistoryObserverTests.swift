import Foundation
import Testing
@testable import Actuali

@Suite(.serialized)
@MainActor
struct HistoryObserverTests {
    private func transaction(
        id: String,
        amount: Int = -1000
    ) -> Transaction {
        Transaction(
            id: id,
            accountId: "account",
            date: 20260906,
            amount: amount,
            payeeId: "payee",
            payeeName: "Groceries",
            categoryId: "category",
            categoryName: "Food",
            notes: nil,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )
    }

    private func makeStore(
        budgetID: String,
        transactions: [Transaction]
    ) -> BudgetStore {
        let store = BudgetStore.previewInstance()
        store.currentBudgetId = budgetID
        store.transactions = transactions
        return store
    }

    private func clearHistory(for budgetID: String) {
        UserDefaults.standard.removeObject(forKey: "history.actions.\(budgetID)")
        HistoryStore.shared.clearLoadedActions()
        HistoryStore.finishUndoRecording()
    }

    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }

    @Test func marksRefreshRemoteOnlyWhenSyncTransitionsToIdle() {
        #expect(HistoryObserver.shouldMarkRemoteRefresh(wasSyncing: true, state: .idle))
        #expect(!HistoryObserver.shouldMarkRemoteRefresh(wasSyncing: false, state: .idle))
        #expect(!HistoryObserver.shouldMarkRemoteRefresh(wasSyncing: true, state: .syncing))
    }

    @Test func reloadOfSameBudgetResetsBaseline() async {
        let budgetID = "history-observer-reload-\(UUID().uuidString)"
        defer { clearHistory(for: budgetID) }

        let original = transaction(id: "original")
        let reloaded = transaction(id: "reloaded")
        let store = makeStore(budgetID: budgetID, transactions: [original])
        let observer = HistoryObserver(store: store)
        await settle()

        store.isLoading = true
        store.transactions = [reloaded]
        await settle()
        store.isLoading = false
        await settle()

        #expect(HistoryStore.shared.actions.isEmpty)
        _ = observer
    }

    @Test func addProducesOneCreatedAction() async {
        let budgetID = "history-observer-add-\(UUID().uuidString)"
        defer { clearHistory(for: budgetID) }

        let existing = transaction(id: "existing")
        let added = transaction(id: "added")
        let store = makeStore(budgetID: budgetID, transactions: [existing])
        let observer = HistoryObserver(store: store)
        await settle()

        store.transactions = [existing, added]
        await settle()

        #expect(HistoryStore.shared.actions.count == 1)
        #expect(HistoryStore.shared.actions.first?.kind == .created)
        #expect(HistoryStore.shared.actions.first?.after.map(\.id) == ["added"])
        _ = observer
    }

    @Test func editProducesOneEditedAction() async {
        let budgetID = "history-observer-edit-\(UUID().uuidString)"
        defer { clearHistory(for: budgetID) }

        let original = transaction(id: "edited", amount: -1000)
        var edited = original
        edited.amount = -1200
        let store = makeStore(budgetID: budgetID, transactions: [original])
        let observer = HistoryObserver(store: store)
        await settle()

        store.transactions = [edited]
        await settle()

        #expect(HistoryStore.shared.actions.count == 1)
        #expect(HistoryStore.shared.actions.first?.kind == .edited)
        #expect(HistoryStore.shared.actions.first?.before.first?.amount == -1000)
        #expect(HistoryStore.shared.actions.first?.after.first?.amount == -1200)
        _ = observer
    }

    @Test func deleteProducesOneDeletedAction() async {
        let budgetID = "history-observer-delete-\(UUID().uuidString)"
        defer { clearHistory(for: budgetID) }

        let existing = transaction(id: "deleted")
        let store = makeStore(budgetID: budgetID, transactions: [existing])
        let observer = HistoryObserver(store: store)
        await settle()

        store.transactions = []
        await settle()

        #expect(HistoryStore.shared.actions.count == 1)
        #expect(HistoryStore.shared.actions.first?.kind == .deleted)
        #expect(HistoryStore.shared.actions.first?.before.first?.id == "deleted")
        #expect(HistoryStore.shared.actions.first?.after.first?.tombstone == true)
        _ = observer
    }

    @Test func publicationDuringSyncRefreshProducesNoHistoryAction() async {
        let budgetID = "history-observer-sync-\(UUID().uuidString)"
        defer { clearHistory(for: budgetID) }

        let original = transaction(id: "remote", amount: -1000)
        var remoteEdit = original
        remoteEdit.amount = -1800
        let store = makeStore(budgetID: budgetID, transactions: [original])
        let observer = HistoryObserver(store: store)
        await settle()

        store.syncState = .syncing
        store.syncState = .idle
        store.transactions = [remoteEdit]
        await settle()

        #expect(HistoryStore.shared.actions.isEmpty)
        _ = observer
    }
}
