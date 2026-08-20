import Foundation
import Testing
@testable import Actuali

struct BudgetMonthOverspentCountTests {

    private func makeCategory(id: String, available: Int, carryover: Int = 0) -> CategoryBudget {
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
            carryover: carryover
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

    // MARK: - isApproachingLimit (the "Almost Spent" filter chip)

    @Test func eightyPercentSpentIsApproachingTheLimit() {
        var category = makeCategory(id: "approaching", available: 2000)
        category.budgeted = 10000
        category.spent = -8000
        #expect(category.isApproachingLimit)
    }

    @Test func plentyLeftIsNotApproachingTheLimit() {
        var category = makeCategory(id: "healthy", available: 6000)
        category.budgeted = 10000
        category.spent = -4000
        #expect(!category.isApproachingLimit)
    }

    // Overspent, fully spent and untouched categories each have their own
    // chip, so none of them may also match "Almost Spent".
    @Test func overspentAndFullySpentAndIdleAreNotApproachingTheLimit() {
        var overspent = makeCategory(id: "overspent", available: -500)
        overspent.budgeted = 10000
        overspent.spent = -10500
        #expect(!overspent.isApproachingLimit)

        var fullySpent = makeCategory(id: "spent", available: 0)
        fullySpent.budgeted = 10000
        fullySpent.spent = -10000
        #expect(!fullySpent.isApproachingLimit)

        var idle = makeCategory(id: "idle", available: 10000)
        idle.budgeted = 10000
        idle.spent = 0
        #expect(!idle.isApproachingLimit)
    }

    // MARK: - rolledOverOverspending

    @Test func negativeCarryoverIsRolledOverOverspending() {
        let category = makeCategory(id: "c", available: -1500, carryover: -1000)
        #expect(category.rolledOverOverspending == -1000)
    }

    @Test func positiveCarryoverIsNotRolledOverOverspending() {
        let category = makeCategory(id: "c", available: -500, carryover: 2000)
        #expect(category.rolledOverOverspending == 0)
    }

    @Test func zeroCarryoverHasNoRolledOverOverspending() {
        let category = makeCategory(id: "c", available: -500)
        #expect(category.rolledOverOverspending == 0)
    }
}
