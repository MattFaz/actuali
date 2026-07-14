import Foundation
import Testing
@testable import Actuali

struct BudgetMonthOverspentCountTests {

    private func makeCategory(id: String, available: Int) -> CategoryBudget {
        CategoryBudget(
            month: "2026-07",
            categoryId: id,
            categoryName: "Category \(id)",
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

    private func makeMonth(availables: [Int]) -> BudgetMonth {
        BudgetMonth(
            month: "2026-07",
            categoryBudgets: availables.enumerated().map { makeCategory(id: "cat\($0.offset)", available: $0.element) }
        )
    }

    @Test func emptyMonthHasNoOverspentCategories() {
        #expect(makeMonth(availables: []).overspentCount == 0)
    }

    @Test func healthyCategoriesDoNotCount() {
        #expect(makeMonth(availables: [5000, 0, 12000]).overspentCount == 0)
    }

    @Test func onlyNegativeAvailableCounts() {
        #expect(makeMonth(availables: [5000, -200, 0, -1]).overspentCount == 2)
    }

    @Test func exactlyZeroAvailableIsNotOverspent() {
        #expect(makeMonth(availables: [0]).overspentCount == 0)
    }
}
