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
}
