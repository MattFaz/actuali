import Foundation
import Testing
@testable import Actuali

/// A category that only received money must not read like spending: the
/// clean row's Spent caption keeps a leading "+" on a net inflow instead of
/// collapsing it into the same positive amount as real spending (GH #102).
@MainActor
struct BudgetStoreSpentCaptionTests {

    private func makeStore() -> BudgetStore {
        let store = BudgetStore.previewInstance()
        store.hideBalances = false
        return store
    }

    @Test func spendingShowsAsPlainPositiveAmount() {
        let store = makeStore()
        defer { UserDefaults.standard.removeObject(forKey: "hideBalances") }
        #expect(store.displaySpentCaption(-5000) == store.formatCurrency(5000))
    }

    @Test func netInflowKeepsALeadingPlus() {
        let store = makeStore()
        defer { UserDefaults.standard.removeObject(forKey: "hideBalances") }
        #expect(store.displaySpentCaption(5000) == "+\(store.formatCurrency(5000))")
    }

    @Test func zeroShowsAsPlainZero() {
        let store = makeStore()
        defer { UserDefaults.standard.removeObject(forKey: "hideBalances") }
        #expect(store.displaySpentCaption(0) == store.formatCurrency(0))
    }

    @Test func maskedWhenBalancesAreHidden() {
        let store = makeStore()
        store.hideBalances = true
        defer { UserDefaults.standard.removeObject(forKey: "hideBalances") }
        #expect(store.displaySpentCaption(5000) == BudgetStore.hiddenBalanceText)
        #expect(store.displaySpentCaption(-5000) == BudgetStore.hiddenBalanceText)
    }
}
