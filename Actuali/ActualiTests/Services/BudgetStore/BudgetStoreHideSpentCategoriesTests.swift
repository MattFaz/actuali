import Foundation
import Testing
@testable import Actuali

/// The "hide spent categories" toggle must default to off, persist like the
/// other display settings, and hide exactly the zero-available categories —
/// overspent (negative) ones stay visible so problems are never masked.
@MainActor
struct BudgetStoreHideSpentCategoriesTests {

    private func makeCategories(availables: [Int]) -> [CategoryBudget] {
        availables.enumerated().map { index, available in
            CategoryBudget(
                month: "2026-08",
                categoryId: "cat\(index)",
                categoryName: "Category \(index)",
                groupId: "g1",
                groupName: "Everyday",
                groupSortOrder: 0,
                categorySortOrder: 0,
                budgeted: 10000,
                spent: 10000 - available,
                available: available,
                carryover: 0
            )
        }
    }

    @Test func defaultsToFalse() {
        UserDefaults.standard.removeObject(forKey: "hideZeroBudgetCategories")
        let store = BudgetStore.previewInstance()
        #expect(store.hideZeroBudgetCategories == false)
    }

    @Test func togglePersistsToUserDefaults() {
        let store = BudgetStore.previewInstance()
        store.hideZeroBudgetCategories = true
        #expect(UserDefaults.standard.bool(forKey: "hideZeroBudgetCategories") == true)
        store.hideZeroBudgetCategories = false
        #expect(UserDefaults.standard.bool(forKey: "hideZeroBudgetCategories") == false)
        UserDefaults.standard.removeObject(forKey: "hideZeroBudgetCategories")
    }

    @Test func hidesOnlyZeroAvailableWhenEnabled() {
        let store = BudgetStore.previewInstance()
        store.hideZeroBudgetCategories = true
        defer { UserDefaults.standard.removeObject(forKey: "hideZeroBudgetCategories") }

        let visible = store.visibleCategoryBudgets(makeCategories(availables: [-100, 0, 500, 0]))
        #expect(visible.map(\.available) == [-100, 500])
    }

    @Test func showsAllWhenDisabled() {
        let store = BudgetStore.previewInstance()
        store.hideZeroBudgetCategories = false
        defer { UserDefaults.standard.removeObject(forKey: "hideZeroBudgetCategories") }

        let visible = store.visibleCategoryBudgets(makeCategories(availables: [-100, 0, 500]))
        #expect(visible.count == 3)
    }

    @Test func showHiddenKeepsHiddenRowsReachableWhenSpentRowsAreHidden() {
        let store = BudgetStore.previewInstance()
        store.hideZeroBudgetCategories = true
        store.showHiddenCategories = true
        defer {
            UserDefaults.standard.removeObject(forKey: "hideZeroBudgetCategories")
            UserDefaults.standard.removeObject(forKey: "showHiddenCategories")
        }
        var categories = makeCategories(availables: [0, 0])
        categories[1].hidden = true

        let visible = store.visibleCategoryBudgets(categories)

        #expect(visible.map(\.categoryId) == ["cat1"])
    }
}
