import Foundation
import Testing
@testable import Actuali

/// The Symbol Only setting must flow through the store's formatters and
/// persist like the other display settings (GH #83).
@MainActor
struct BudgetStoreCurrencySymbolTests {

    @Test func standardSymbolsByDefault() {
        let store = BudgetStore.previewInstance()
        #expect(!store.useNarrowCurrencySymbol)
    }

    /// Locale-independent: the narrow presentation never includes the ISO
    /// letters, while every locale renders foreign NZD with some "NZ" prefix.
    @Test func narrowSymbolAppliesToFormatters() {
        let store = BudgetStore.previewInstance()
        store.currencyCode = "NZD"
        store.useNarrowCurrencySymbol = true
        #expect(!store.formatCurrency(123_450).contains("NZ"))
        #expect(!store.formatCurrencyWholeUnits(123_450).contains("NZ"))
        #expect(store.formatCurrency(123_450).contains("$"))
    }

    @Test func togglePersistsToUserDefaults() {
        let store = BudgetStore.previewInstance()
        store.useNarrowCurrencySymbol = true
        #expect(UserDefaults.standard.object(forKey: "useNarrowCurrencySymbol") as? Bool == true)
        store.useNarrowCurrencySymbol = false
        #expect(UserDefaults.standard.object(forKey: "useNarrowCurrencySymbol") as? Bool == false)
    }
}
