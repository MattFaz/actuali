import Foundation
import Testing
@testable import Actuali

/// The hide-balances privacy mask must replace every formatted amount with
/// the shared placeholder while on, format normally while off, and persist
/// like the other display settings.
@MainActor
struct BudgetStoreBalanceVisibilityTests {

    @Test func balancesShowByDefault() {
        let store = BudgetStore.previewInstance()
        #expect(!store.hideBalances)
        #expect(store.displayBalance(123456) == store.formatCurrency(123456))
        #expect(store.displayBalanceWholeUnits(123456) == store.formatCurrencyWholeUnits(123456))
    }

    @Test func displayBalanceMasksWhenHidden() {
        let store = BudgetStore.previewInstance()
        store.hideBalances = true
        #expect(store.displayBalance(123456) == BudgetStore.hiddenBalanceText)
        #expect(store.displayBalanceWholeUnits(123456) == BudgetStore.hiddenBalanceText)
    }

    /// The mask must never leak a digit, sign, or currency symbol for any
    /// amount, including the values most likely to hit formatter edge cases.
    @Test func maskIsAmountIndependent() {
        let store = BudgetStore.previewInstance()
        store.hideBalances = true
        for cents in [0, -1, 1, Int.max, Int.min + 1, -987654321] {
            #expect(store.displayBalance(cents) == BudgetStore.hiddenBalanceText)
        }
    }

    @Test func togglePersistsToUserDefaults() {
        let store = BudgetStore.previewInstance()
        store.hideBalances = true
        #expect(UserDefaults.standard.object(forKey: "hideBalances") as? Bool == true)
        store.hideBalances = false
        #expect(UserDefaults.standard.object(forKey: "hideBalances") as? Bool == false)
    }
}
