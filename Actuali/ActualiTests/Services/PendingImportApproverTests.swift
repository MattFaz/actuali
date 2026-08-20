import Foundation
import Testing
@testable import Actuali

@MainActor
struct PendingImportApproverTests {

    private func makeStore() -> BudgetStore {
        let store = BudgetStore.previewInstance()
        store.currentBudgetId = "test-budget"
        return store
    }

    private func account(_ id: String, _ name: String, closed: Bool = false) -> Account {
        Account(id: id, name: name, type: .checking, offBudget: false, closed: closed,
                sortOrder: 0, balance: 0)
    }

    @Test func refusesInvalidAmount() async {
        let store = makeStore()
        let approver = PendingImportApprover(store: store)

        let nilAmountItem = PendingImport(amount: nil, payee: "Test", rawText: "test")
        await #expect(throws: PendingImportApprover.ApproveError.invalidAmount) {
            try await approver.approve(nilAmountItem)
        }

        let zeroAmountItem = PendingImport(amount: 0, payee: "Test", rawText: "test")
        await #expect(throws: PendingImportApprover.ApproveError.invalidAmount) {
            try await approver.approve(zeroAmountItem)
        }

        let negativeAmountItem = PendingImport(amount: -15.0, payee: "Test", rawText: "test")
        await #expect(throws: PendingImportApprover.ApproveError.invalidAmount) {
            try await approver.approve(negativeAmountItem)
        }
    }

    @Test func refusesWhenNoAccountAvailable() async {
        let store = makeStore()
        store.accounts = []
        store.defaultAccountId = nil

        let approver = PendingImportApprover(store: store)
        let item = PendingImport(amount: 25.0, payee: "Coffee", cardHint: "nonexistent", rawText: "msg")

        await #expect(throws: PendingImportApprover.ApproveError.noAccountAvailable) {
            try await approver.approve(item)
        }
    }

    @Test func refusesWhenTargetAccountIsClosed() async {
        let store = makeStore()
        let closedAcct = account("acct_closed", "Closed Account", closed: true)
        store.accounts = [closedAcct]
        store.defaultAccountId = closedAcct.id

        let approver = PendingImportApprover(store: store)
        let item = PendingImport(amount: 25.0, payee: "Coffee", rawText: "msg")

        await #expect(throws: PendingImportApprover.ApproveError.accountClosed) {
            try await approver.approve(item)
        }
    }
}
