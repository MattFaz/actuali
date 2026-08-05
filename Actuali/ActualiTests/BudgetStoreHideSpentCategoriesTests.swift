import Foundation
import Testing
@testable import Actuali

/// The "hide spent categories" toggle must default to off and persist like
/// the other display settings.
@MainActor
struct BudgetStoreHideSpentCategoriesTests {

    @Test func defaultsToFalse() {
        let store = BudgetStore.previewInstance()
        #expect(store.hideZeroBudgetCategories == false)
    }

    @Test func togglePersistsToUserDefaults() {
        let store = BudgetStore.previewInstance()
        store.hideZeroBudgetCategories = true
        #expect(UserDefaults.standard.bool(forKey: "hideZeroBudgetCategories") == true)
        store.hideZeroBudgetCategories = false
        #expect(UserDefaults.standard.bool(forKey: "hideZeroBudgetCategories") == false)
    }
}
