import Testing
@testable import Actuali

struct BudgetMonthSpentTests {
    @Test func excludedCategoriesDoNotContributeToSpent() {
        let budget = BudgetMonth(
            month: "2026-09",
            categoryBudgets: [
                makeCategory(id: "investments", spent: -5000),
                makeCategory(id: "groceries", spent: -3000),
            ]
        )

        #expect(budget.totalSpent == -8000)
        #expect(budget.totalSpent(excluding: ["investments"]) == -3000)
        #expect(budget.totalSpent(excluding: ["missing"]) == -8000)
    }

    private func makeCategory(id: String, spent: Int) -> CategoryBudget {
        CategoryBudget(
            month: "2026-09",
            categoryId: id,
            categoryName: id,
            groupId: "group",
            groupName: "Group",
            groupSortOrder: 0,
            categorySortOrder: 0,
            budgeted: 10000,
            spent: spent,
            available: 10000 + spent,
            carryover: 0,
            goal: nil
        )
    }
}
