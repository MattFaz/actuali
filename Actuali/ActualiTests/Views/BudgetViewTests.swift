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

    @Test func groupHeaderLabelIncludesBudgetedTotal() {
        let label = BudgetGroupHeader.totalsAccessibilityLabel(
            name: "Everyday",
            isCollapsed: false,
            budgeted: "$100.00",
            spent: "-$40.00",
            balance: "$60.00"
        )

        #expect(label == "Everyday, expanded, budgeted $100.00, spent -$40.00, balance $60.00")
    }
}
