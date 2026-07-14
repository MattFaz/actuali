import Foundation
import Testing
@testable import Actuali

/// The Budget tab badge count must respect the "Overspent Badge" display
/// setting: the real overspent count when enabled, always 0 when disabled.
@MainActor
struct BudgetStoreOverspentBadgeTests {

    private func makeMonth(availables: [Int]) -> BudgetMonth {
        BudgetMonth(
            month: "2026-07",
            categoryBudgets: availables.enumerated().map { index, available in
                CategoryBudget(
                    month: "2026-07",
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
        )
    }

    @Test func badgeCountsOverspentWhenEnabled() {
        let store = BudgetStore.previewInstance()
        store.showOverspentBadge = true
        store.currentBudgetMonth = makeMonth(availables: [-100, 500, -1])
        #expect(store.overspentBadgeCount == 2)
    }

    @Test func badgeIsZeroWhenDisabled() {
        let store = BudgetStore.previewInstance()
        store.showOverspentBadge = false
        store.currentBudgetMonth = makeMonth(availables: [-100, 500, -1])
        #expect(store.overspentBadgeCount == 0)
    }

    @Test func badgeIsZeroWithoutLoadedMonth() {
        let store = BudgetStore.previewInstance()
        store.showOverspentBadge = true
        store.currentBudgetMonth = nil
        #expect(store.overspentBadgeCount == 0)
    }

    @Test func settingDefaultsToOn() {
        UserDefaults.standard.removeObject(forKey: "showOverspentBadge")
        let store = BudgetStore.previewInstance()
        #expect(store.showOverspentBadge)
    }
}
