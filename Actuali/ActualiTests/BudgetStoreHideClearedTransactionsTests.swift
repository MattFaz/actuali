import Foundation
import Testing
@testable import Actuali

/// The "hide cleared transactions" toggle (GH #133) must default to off and
/// persist like the other display settings.
@MainActor
struct BudgetStoreHideClearedTransactionsTests {

    @Test func defaultsToFalse() {
        UserDefaults.standard.removeObject(forKey: "hideClearedTransactions")
        let store = BudgetStore.previewInstance()
        #expect(store.hideClearedTransactions == false)
    }

    @Test func togglePersistsToUserDefaults() {
        let store = BudgetStore.previewInstance()
        store.hideClearedTransactions = true
        #expect(UserDefaults.standard.bool(forKey: "hideClearedTransactions") == true)
        store.hideClearedTransactions = false
        #expect(UserDefaults.standard.bool(forKey: "hideClearedTransactions") == false)
        UserDefaults.standard.removeObject(forKey: "hideClearedTransactions")
    }
}
