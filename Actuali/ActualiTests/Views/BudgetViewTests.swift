import Testing
@testable import Actuali

struct BudgetViewTests {

    @Test func displayedGroupsIncludeIncomeWhenPresent() {
        let ids = BudgetView.displayedGroupIDs(
            groupIDs: ["essentials", "lifestyle"],
            hasIncome: true
        )

        #expect(ids == ["essentials", "lifestyle", BudgetView.incomeGroupCollapseID])
    }

    @Test func displayedGroupsExcludeIncomeWhenAbsent() {
        let ids = BudgetView.displayedGroupIDs(
            groupIDs: ["essentials", "lifestyle"],
            hasIncome: false
        )

        #expect(ids == ["essentials", "lifestyle"])
    }
}
