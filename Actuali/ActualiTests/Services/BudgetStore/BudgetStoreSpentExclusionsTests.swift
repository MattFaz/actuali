import Foundation
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreSpentExclusionsTests {
    @Test func categoryCanBeExcludedAndIncludedAgain() {
        let store = BudgetStore.previewInstance()

        #expect(store.isCategoryIncludedInSpent("investments"))
        store.setCategoryIncludedInSpent(false, categoryId: "investments")
        #expect(!store.isCategoryIncludedInSpent("investments"))
        store.setCategoryIncludedInSpent(true, categoryId: "investments")
        #expect(store.isCategoryIncludedInSpent("investments"))
    }

    @Test func exclusionsPersistPerBudgetAndReloadOnSwitch() {
        let keyA = "excludedFromSpentCategoryIds.budget-a"
        let keyB = "excludedFromSpentCategoryIds.budget-b"
        let previousBudgetId = UserDefaults.standard.string(forKey: "currentBudgetId")
        let store = BudgetStore.previewInstance()
        defer {
            store.currentBudgetId = previousBudgetId
            UserDefaults.standard.removeObject(forKey: keyA)
            UserDefaults.standard.removeObject(forKey: keyB)
        }

        store.currentBudgetId = "budget-a"
        store.setCategoryIncludedInSpent(false, categoryId: "investments")
        #expect(UserDefaults.standard.array(forKey: keyA) as? [String] == ["investments"])

        store.currentBudgetId = "budget-b"
        #expect(store.isCategoryIncludedInSpent("investments"))
        store.currentBudgetId = "budget-a"
        #expect(!store.isCategoryIncludedInSpent("investments"))
    }
}
