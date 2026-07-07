import Foundation
import Testing
@testable import Actuali

struct CategoryBudgetProgressTests {

    private func makeCategory(
        budgeted: Int,
        spent: Int,
        available: Int,
        carryover: Int = 0
    ) -> CategoryBudget {
        CategoryBudget(
            month: "2026-07",
            categoryId: "cat1",
            categoryName: "Groceries",
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

    @Test func halfSpentIsHalfFull() {
        let category = makeCategory(budgeted: 10000, spent: -5000, available: 5000)
        #expect(category.progressFraction == 0.5)
    }

    @Test func nothingSpentIsEmpty() {
        let category = makeCategory(budgeted: 10000, spent: 0, available: 10000)
        #expect(category.progressFraction == 0.0)
    }

    @Test func overspentIsCappedAtFull() {
        let category = makeCategory(budgeted: 10000, spent: -12000, available: -2000)
        #expect(category.progressFraction == 1.0)
    }

    @Test func spendingWithNoBudgetIsFull() {
        let category = makeCategory(budgeted: 0, spent: -3000, available: -3000)
        #expect(category.progressFraction == 1.0)
    }

    @Test func carryoverCountsTowardCapacity() {
        // Nothing budgeted this month, but carryover leaves 5000 available
        // after spending 5000: the bar should read half, matching the
        // displayed Available amount.
        let category = makeCategory(budgeted: 0, spent: -5000, available: 5000, carryover: 10000)
        #expect(category.progressFraction == 0.5)
    }

    @Test func zeroActivityHasNoFraction() {
        let category = makeCategory(budgeted: 0, spent: 0, available: 0)
        #expect(category.progressFraction == 0.0)
    }

    @Test func barHiddenWhenNoBudgetAndNoSpending() {
        let category = makeCategory(budgeted: 0, spent: 0, available: 0)
        #expect(!category.showsProgressBar)
    }

    @Test func barShownWhenBudgeted() {
        let category = makeCategory(budgeted: 10000, spent: 0, available: 10000)
        #expect(category.showsProgressBar)
    }

    @Test func barShownWhenSpendingWithoutBudget() {
        let category = makeCategory(budgeted: 0, spent: -3000, available: -3000)
        #expect(category.showsProgressBar)
    }
}
