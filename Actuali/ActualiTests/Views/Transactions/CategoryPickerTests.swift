import Testing
@testable import Actuali

/// The picker follows the Budget tab: expense groups keep their stored order,
/// income groups move to the bottom.
struct CategoryPickerTests {
    @Test func movesIncomeGroupsToTheEndWithoutReorderingTheRest() {
        let groups = [
            CategoryGroup(
                id: "bills",
                name: "Bills",
                isIncome: false,
                hidden: false,
                sortOrder: 1,
                categories: []
            ),
            CategoryGroup(
                id: "income",
                name: "Income",
                isIncome: true,
                hidden: false,
                sortOrder: 2,
                categories: []
            ),
            CategoryGroup(
                id: "food",
                name: "Food",
                isIncome: false,
                hidden: false,
                sortOrder: 3,
                categories: []
            ),
            CategoryGroup(
                id: "other-income",
                name: "Other Income",
                isIncome: true,
                hidden: false,
                sortOrder: 4,
                categories: []
            ),
        ]

        #expect(
            CategoryPickerView.incomeLast(groups).map(\.id)
                == ["bills", "food", "income", "other-income"]
        )
    }

    @Test func keepsTheOrderWhenNoGroupIsIncome() {
        let groups = [
            CategoryGroup(
                id: "bills",
                name: "Bills",
                isIncome: false,
                hidden: false,
                sortOrder: 2,
                categories: []
            ),
            CategoryGroup(
                id: "food",
                name: "Food",
                isIncome: false,
                hidden: false,
                sortOrder: 1,
                categories: []
            ),
        ]

        #expect(CategoryPickerView.incomeLast(groups).map(\.id) == ["bills", "food"])
        #expect(CategoryPickerView.incomeLast([]).isEmpty)
    }

    private func category(_ id: String, available: Int) -> CategoryBudget {
        CategoryBudget(
            month: "2026-11",
            categoryId: id,
            categoryName: id,
            groupId: "group",
            groupName: "Group",
            groupSortOrder: 0,
            categorySortOrder: 0,
            budgeted: 0,
            spent: 0,
            available: available,
            carryover: 0,
            goal: nil
        )
    }

    @Test func balancesComeFromTheBudgetMonthByCategory() {
        let budget = BudgetMonth(
            month: "2026-11",
            categoryBudgets: [category("food", available: 51250), category("fun", available: -3000)]
        )

        #expect(CategoryPickerView.availableBalances(in: budget) == ["food": 51250, "fun": -3000])
    }

    @Test func hiddenCategoriesKeepTheirBalance() {
        let budget = BudgetMonth(
            month: "2026-11",
            categoryBudgets: [category("food", available: 100)],
            hiddenCategoryBudgets: [category("old", available: -200)]
        )

        #expect(CategoryPickerView.availableBalances(in: budget) == ["food": 100, "old": -200])
    }

    @Test func noBudgetMeansNoBalances() {
        #expect(CategoryPickerView.availableBalances(in: nil).isEmpty)
    }
}
