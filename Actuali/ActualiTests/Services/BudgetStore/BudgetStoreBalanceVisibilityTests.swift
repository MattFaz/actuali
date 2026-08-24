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

    @Test func decimalPlacePreferenceFormatsDisplayOnlyAsWholeUnits() {
        let store = BudgetStore.previewInstance()
        store.currencyCode = "USD"
        store.useNarrowCurrencySymbol = true
        store.hideDecimalPlaces = true

        #expect(store.displayBalance(123_456) == store.formatCurrencyWholeUnits(123_456))
        // Exact-value workflows such as reconciliation and split remainders
        // deliberately bypass the display preference.
        #expect(store.formatCurrency(123_456) != store.formatCurrencyWholeUnits(123_456))
        #expect(store.displaySpentCaption(-123_456) == store.formatCurrencyWholeUnits(123_456))

        store.hideDecimalPlaces = false
        let standard = CurrencyAmountFormat.string(
            cents: 123_456, currencyCode: store.currencyCode,
            narrowSymbol: store.useNarrowCurrencySymbol)
        #expect(store.displayBalance(123_456) == standard)
    }

    @Test func decimalPlacePreferencePersistsToUserDefaults() {
        let store = BudgetStore.previewInstance()
        store.hideDecimalPlaces = true
        #expect(UserDefaults.standard.object(forKey: "hideDecimalPlaces") as? Bool == true)
        store.hideDecimalPlaces = false
        #expect(UserDefaults.standard.object(forKey: "hideDecimalPlaces") as? Bool == false)
    }

    @Test func shakeToHideBalancesDefaultsToTrue() {
        let store = BudgetStore.previewInstance()
        #expect(store.shakeToHideBalances)
    }

    @Test func shakeToHideBalancesPersistsToUserDefaults() {
        let store = BudgetStore.previewInstance()
        store.shakeToHideBalances = false
        #expect(UserDefaults.standard.object(forKey: "shakeToHideBalances") as? Bool == false)
        store.shakeToHideBalances = true
        #expect(UserDefaults.standard.object(forKey: "shakeToHideBalances") as? Bool == true)
    }

    @Test func handleDeviceShakeTogglesHideBalancesWhenEnabled() {
        let store = BudgetStore.previewInstance()
        store.shakeToHideBalances = true
        store.hideBalances = false

        store.handleDeviceShake()
        #expect(store.hideBalances)

        store.handleDeviceShake()
        #expect(!store.hideBalances)
    }

    @Test func handleDeviceShakeNoOpsWhenDisabled() {
        let store = BudgetStore.previewInstance()
        store.shakeToHideBalances = false
        store.hideBalances = false

        store.handleDeviceShake()
        #expect(!store.hideBalances)
    }
}

