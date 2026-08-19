import Foundation
import Testing
@testable import Actuali

/// The tracking-budget summary figures on `BudgetMonth`. These mirror upstream
/// loot-core `tracking.ts`: `real-saved` (actual income + actual spent) and
/// `total-saved` (budgeted income - budgeted expenses).
struct BudgetMonthTrackingSummaryTests {

    @Test func budgetTypeFollowsPresenceOfToBudget() {
        let tracking = BudgetMonth(month: "2026-07", categoryBudgets: [], toBudget: nil)
        let envelope = BudgetMonth(month: "2026-07", categoryBudgets: [], toBudget: 0)

        #expect(tracking.isTrackingBudget)
        #expect(!envelope.isTrackingBudget)
    }

    private func expense(id: String, budgeted: Int, spent: Int) -> CategoryBudget {
        CategoryBudget(
            month: "2026-07",
            categoryId: id,
            categoryName: "Category \(id)",
            groupId: "g1",
            groupName: "Everyday",
            groupSortOrder: 0,
            categorySortOrder: 0,
            budgeted: budgeted,
            spent: spent,
            available: budgeted + spent,
            carryover: 0
        )
    }

    private func income(id: String, budgeted: Int, received: Int) -> IncomeCategory {
        IncomeCategory(
            month: "2026-07",
            categoryId: id,
            categoryName: "Income \(id)",
            groupName: "Income",
            sortOrder: 0,
            budgeted: budgeted,
            received: received
        )
    }

    /// The exact figures from the Actual webapp's tracking summary (cents):
    /// income 11,635.00 of budgeted 11,008.90; expenses -7,629.42 of budgeted
    /// 4,952.66 → Saved 4,005.58, Projected 6,056.24.
    @Test func matchesWebappSummaryFixture() {
        let month = BudgetMonth(
            month: "2026-07",
            categoryBudgets: [expense(id: "e", budgeted: 495_266, spent: -762_942)],
            incomeCategories: [income(id: "i", budgeted: 1_100_890, received: 1_163_500)]
        )

        #expect(month.totalBudgetedIncome == 1_100_890)
        #expect(month.savedActual == 400_558)
        #expect(month.projectedSavings == 605_624)
    }

    @Test func totalBudgetedIncomeSumsAllIncomeCategories() {
        let month = BudgetMonth(
            month: "2026-07",
            categoryBudgets: [],
            incomeCategories: [
                income(id: "a", budgeted: 300_000, received: 0),
                income(id: "b", budgeted: 150_000, received: 0)
            ]
        )
        #expect(month.totalBudgetedIncome == 450_000)
    }

    @Test func savedActualIsNegativeWhenSpendingOutrunsIncome() {
        let month = BudgetMonth(
            month: "2026-07",
            categoryBudgets: [expense(id: "e", budgeted: 100_000, spent: -250_000)],
            incomeCategories: [income(id: "i", budgeted: 200_000, received: 200_000)]
        )
        // 200,000 received + (-250,000) spent = -50,000
        #expect(month.savedActual == -50_000)
    }

    @Test func projectedSavingsIsNegativeWhenBudgetedExpensesExceedIncome() {
        let month = BudgetMonth(
            month: "2026-07",
            categoryBudgets: [expense(id: "e", budgeted: 300_000, spent: 0)],
            incomeCategories: [income(id: "i", budgeted: 200_000, received: 0)]
        )
        // 200,000 budgeted income - 300,000 budgeted expenses = -100,000
        #expect(month.projectedSavings == -100_000)
    }
}
