import Foundation
import Testing
@testable import Actuali

/// The "hide closed accounts" toggle (GH #277) must default to off, persist
/// like the other display settings, and drop only closed accounts — open ones
/// stay visible whatever the toggle says.
@MainActor
struct BudgetStoreHideClosedAccountsTests {

    private func makeAccounts() -> [Account] {
        [
            Account(id: "a1", name: "Checking", type: .checking, offBudget: false, closed: false, sortOrder: 0, balance: 5000),
            Account(id: "a2", name: "Old Savings", type: .savings, offBudget: false, closed: true, sortOrder: 1, balance: 0),
            Account(id: "a3", name: "Old Card", type: .credit, offBudget: true, closed: true, sortOrder: 2, balance: -100)
        ]
    }

    @Test func defaultsToFalse() {
        UserDefaults.standard.removeObject(forKey: "hideClosedAccounts")
        let store = BudgetStore.previewInstance()
        #expect(store.hideClosedAccounts == false)
    }

    @Test func togglePersistsToUserDefaults() {
        let store = BudgetStore.previewInstance()
        store.hideClosedAccounts = true
        #expect(UserDefaults.standard.bool(forKey: "hideClosedAccounts") == true)
        store.hideClosedAccounts = false
        #expect(UserDefaults.standard.bool(forKey: "hideClosedAccounts") == false)
        UserDefaults.standard.removeObject(forKey: "hideClosedAccounts")
    }

    @Test func hidesClosedAccountsWhenEnabled() {
        let store = BudgetStore.previewInstance()
        store.accounts = makeAccounts()
        store.hideClosedAccounts = true
        defer { UserDefaults.standard.removeObject(forKey: "hideClosedAccounts") }

        #expect(store.visibleClosedAccounts.isEmpty)
    }

    @Test func showsClosedAccountsWhenDisabled() {
        let store = BudgetStore.previewInstance()
        store.accounts = makeAccounts()
        store.hideClosedAccounts = false
        defer { UserDefaults.standard.removeObject(forKey: "hideClosedAccounts") }

        #expect(store.visibleClosedAccounts.map(\.id) == ["a2", "a3"])
    }
}
