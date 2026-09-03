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

    @Test func overspendingAlwaysRequiresCheckIn() {
        let month = makeMonth(availables: [-8500])
        #expect(month.hasCheckInIssues(uncategorizedCount: 0))
    }

    // Money left to assign has no check-in row (the Budget summary shows
    // it), so it must not suppress "Budget looks good" either.
    @Test func moneyLeftToAssignAloneIsNotACheckInIssue() {
        var month = makeMonth(availables: [5000])
        month.toBudget = 12000
        #expect(!month.hasCheckInIssues(uncategorizedCount: 0))
    }

    // MARK: - overspentCategories (the badge's explanation, GH #138)

    @Test func overspentCategoriesListsOnlyTheOnesInTheRed() {
        let month = makeMonth(availables: [5000, -200, 0, -1])
        #expect(month.overspentCategories.map(\.available) == [-200, -1])
    }

    @Test func overspentCategoriesOrdersWorstFirst() {
        let month = makeMonth(availables: [-1, -5000, 300, -200])
        #expect(month.overspentCategories.map(\.available) == [-5000, -200, -1])
    }

    @Test func overspentCategoriesIsEmptyWhenNothingIsOverspent() {
        #expect(makeMonth(availables: [5000, 0]).overspentCategories.isEmpty)
    }

    @Test func checkInSeparatesUnassignedAndApproachingCategories() {
        var unassigned = makeCategory(id: "unassigned", available: 0)
        unassigned.budgeted = 0
        unassigned.spent = 0

        var approaching = makeCategory(id: "approaching", available: 1000)
        approaching.budgeted = 10000
        approaching.spent = -9000

        var healthy = makeCategory(id: "healthy", available: 6000)
        healthy.budgeted = 10000
        healthy.spent = -4000

        let month = BudgetMonth(
            month: "2026-07",
            categoryBudgets: [healthy, approaching, unassigned],
            toBudget: 5000
        )

        #expect(month.unassignedCategories.map(\.categoryId) == ["unassigned"])
        #expect(month.approachingLimitCategories.map(\.categoryId) == ["approaching"])
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
