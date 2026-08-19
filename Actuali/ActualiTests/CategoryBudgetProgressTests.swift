import Foundation
import Testing
@testable import Actuali

struct CategoryBudgetProgressTests {

    private func makeCategory(
        id: String = "cat1",
        groupId: String = "g1",
        budgeted: Int,
        spent: Int,
        available: Int,
        carryover: Int = 0
    ) -> CategoryBudget {
        CategoryBudget(
            month: "2026-07",
            categoryId: id,
            categoryName: "Groceries",
            groupId: groupId,
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

    @Test func progressStatesDistinguishActionableCategoryConditions() {
        #expect(makeCategory(budgeted: 0, spent: 0, available: 0).progressState == .unassigned)
        #expect(makeCategory(budgeted: 10000, spent: 0, available: 10000).progressState == .funded)
        #expect(makeCategory(budgeted: 10000, spent: -4000, available: 6000).progressState == .spending)
        #expect(makeCategory(budgeted: 10000, spent: -10000, available: 0).progressState == .spent)
        #expect(makeCategory(budgeted: 10000, spent: -12000, available: -2000).progressState == .overspent)
    }

    @Test func quickAssignUsesActualHistoryAndProducesFinalAmounts() {
        let current = makeCategory(budgeted: 10000, spent: -4000, available: 6000)
        let history = [
            makeCategory(budgeted: 9000, spent: -8000, available: 1000),
            makeCategory(budgeted: 6000, spent: -4000, available: 2000),
            makeCategory(budgeted: 3000, spent: 1000, available: 4000)
        ]
        let byKind = Dictionary(uniqueKeysWithValues:
            current.quickAssignSuggestions(history: history).map { ($0.kind, $0.amount) })

        #expect(byKind[.spentLastMonth] == 8000)
        #expect(byKind[.assignedLastMonth] == 9000)
        #expect(byKind[.averageSpent] == 4000)
        #expect(byKind[.resetAvailable] == 4000)
        #expect(byKind[.setToZero] == 0)
    }

    @Test func quickAssignOmitsUnavailableHistoricalChoices() {
        let current = makeCategory(budgeted: 0, spent: 0, available: 0)
        #expect(current.quickAssignSuggestions(history: []).isEmpty)
    }

    // With one history month the average equals Spent Last Month; offering
    // both would just duplicate the suggestion.
    @Test func quickAssignOmitsAverageForASingleHistoryMonth() {
        let current = makeCategory(budgeted: 10000, spent: -4000, available: 6000)
        let history = [makeCategory(budgeted: 9000, spent: -8000, available: 1000)]
        let kinds = current.quickAssignSuggestions(history: history).map(\.kind)
        #expect(!kinds.contains(.averageSpent))
        #expect(kinds.contains(.spentLastMonth))
    }

    @Test func coverSourcesPrioritizeFullCoverageThenSameGroup() {
        let overspent = makeCategory(id: "target", groupId: "home", budgeted: 0, spent: -5000, available: -5000)
        let partialSameGroup = makeCategory(id: "partial", groupId: "home", budgeted: 3000, spent: 0, available: 3000)
        let largeOtherGroup = makeCategory(id: "large", groupId: "other", budgeted: 12000, spent: 0, available: 12000)
        let smallSameGroup = makeCategory(id: "small", groupId: "home", budgeted: 6000, spent: 0, available: 6000)
        let context = BudgetTransferContext(
            category: overspent,
            budget: BudgetMonth(
                month: overspent.month,
                categoryBudgets: [partialSameGroup, largeOtherGroup, smallSameGroup],
                toBudget: 0
            )
        )

        #expect(BudgetTransferSheet.rankedCategories(context).map(\.categoryId)
            == ["small", "large", "partial"])
        #expect(!BudgetTransferSheet.canUseToBudget(context))
    }
}
