import Foundation
import Testing
@testable import Actuali

@MainActor
struct BudgetMonthSelectionTests {
    @Test func lastViewedMonthPersistsPerBudget() {
        let budgetId = "test-budget-\(UUID().uuidString)"
        let key = "lastViewedBudgetMonth_\(budgetId)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let store = BudgetStore.previewInstance()
        store.currentBudgetId = budgetId

        #expect(store.lastViewedBudgetMonth == nil)
        store.lastViewedBudgetMonth = "2026-08"
        #expect(UserDefaults.standard.string(forKey: key) == "2026-08")
        #expect(store.lastViewedBudgetMonth == "2026-08")
    }
}
