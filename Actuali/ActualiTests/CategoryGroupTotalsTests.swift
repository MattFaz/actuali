import Foundation
import Testing
@testable import Actuali

struct CategoryGroupTotalsTests {

    private func makeCategory(
        id: String,
        budgeted: Int,
        spent: Int,
        available: Int,
        carryover: Int = 0
    ) -> CategoryBudget {
        CategoryBudget(
            month: "2026-08",
            categoryId: id,
            categoryName: "Category \(id)",
            groupId: "g1",
            groupName: "Everyday",
            groupSortOrder: 0,
            categorySortOrder: 0,
            budgeted: budgeted,
            spent: spent,
            available: available,
            carryover: carryover
        )
    }

    @Test func emptyGroupTotalsZero() {
        let totals = CategoryGroupTotals([])
        #expect(totals.budgeted == 0)
        #expect(totals.spent == 0)
        #expect(totals.balance == 0)
    }

    @Test func sumsEachColumnIndependently() {
        let totals = CategoryGroupTotals([
            makeCategory(id: "a", budgeted: 10000, spent: -4000, available: 6000),
            makeCategory(id: "b", budgeted: 5000, spent: -5000, available: 0),
            makeCategory(id: "c", budgeted: 2500, spent: -3000, available: -500)
        ])
        #expect(totals.budgeted == 17500)
        #expect(totals.spent == -12000)
        #expect(totals.balance == 5500)
    }

    /// Carryover lives inside each category's `available`, so a group holding
    /// rolled-over overspending totals lower than budgeted minus spent.
    @Test func balanceFollowsAvailableIncludingCarryover() {
        let totals = CategoryGroupTotals([
            makeCategory(id: "a", budgeted: 10000, spent: -2000, available: 3000, carryover: -5000),
            makeCategory(id: "b", budgeted: 0, spent: 0, available: 1500, carryover: 1500)
        ])
        #expect(totals.balance == 4500)
    }

    /// Inflows to an expense category make `spent` net positive; the total has
    /// to carry that through rather than summing absolute values.
    @Test func netsInflowsAgainstOutflows() {
        let totals = CategoryGroupTotals([
            makeCategory(id: "a", budgeted: 0, spent: -3000, available: -3000),
            makeCategory(id: "b", budgeted: 0, spent: 5000, available: 5000)
        ])
        #expect(totals.spent == 2000)
    }
}
