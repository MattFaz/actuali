import Testing
@testable import Actuali

struct BudgetStoreEnvelopeBudgetSummaryTests {
    @Test("Budget months accept only YYYY-MM")
    func budgetMonthValidation() {
        #expect(BudgetStore.isValidBudgetMonth("2026-09"))
        #expect(!BudgetStore.isValidBudgetMonth("2026-9"))
        #expect(!BudgetStore.isValidBudgetMonth("09-2026"))
        #expect(!BudgetStore.isValidBudgetMonth("2026-13"))
        #expect(!BudgetStore.isValidBudgetMonth("2026/09"))
    }

    @Test("Empty month is a safe summary baseline")
    func emptyMonthIsBaseline() {
        let budget = BudgetMonth(month: "2026-09", categoryBudgets: [], toBudget: 0)
        #expect(BudgetStore.isSummaryBaseline(budget))
    }

    @Test("A held amount keeps an empty month from being a baseline")
    func bufferedMonthIsNotBaseline() {
        var budget = BudgetMonth(month: "2026-09", categoryBudgets: [], toBudget: 0)
        budget.buffered = 100
        #expect(!BudgetStore.isSummaryBaseline(budget))
    }

    @Test("Income activity prevents a month from being treated as baseline")
    func activeMonthIsNotBaseline() {
        var budget = BudgetMonth(month: "2026-09", categoryBudgets: [], toBudget: 0)
        budget.incomeCategories = [
            IncomeCategory(
                month: "2026-09",
                categoryId: "income",
                categoryName: "Income",
                groupName: "Income",
                sortOrder: 0,
                budgeted: 0,
                received: 100
            )
        ]
        #expect(!BudgetStore.isSummaryBaseline(budget))
    }

    @Test("January and December month shifts cross the year")
    func yearBoundaryShift() {
        #expect(BudgetStore.shiftBudgetMonth("2026-01", by: -1) == "2025-12")
        #expect(BudgetStore.shiftBudgetMonth("2026-12", by: 1) == "2027-01")
    }

    @Test("Summary reconciles available funds, overspending, budgeted amount, and To Budget")
    func summaryReconciliation() {
        let summary = BudgetStore.makeEnvelopeBudgetSummary(
            availableFunds: 1_500,
            lastMonthOverspent: -200,
            budgeted: 800,
            toBudget: 100,
            manualBuffered: 0
        )

        #expect(summary.availableFunds == 1_500)
        #expect(summary.lastMonthOverspent == -200)
        #expect(summary.budgeted == 800)
        #expect(summary.toBudget == 100)
        #expect(summary.forNextMonth == 400)
        #expect(summary.manualBuffered == 0)
        #expect(summary.autoBuffered == 400)
    }

    @Test("Manual buffer suppresses the inferred auto-buffer amount")
    func manualBufferTakesPriority() {
        let summary = BudgetStore.makeEnvelopeBudgetSummary(
            availableFunds: 1_500,
            lastMonthOverspent: 0,
            budgeted: 500,
            toBudget: 500,
            manualBuffered: 250
        )

        #expect(summary.forNextMonth == 500)
        #expect(summary.manualBuffered == 250)
        #expect(summary.autoBuffered == 0)
    }

    @Test("Negative For next month never creates an auto-buffer")
    func negativeNextMonthDoesNotAutoBuffer() {
        let summary = BudgetStore.makeEnvelopeBudgetSummary(
            availableFunds: 100,
            lastMonthOverspent: -200,
            budgeted: 300,
            toBudget: 0,
            manualBuffered: 0
        )

        #expect(summary.forNextMonth == -400)
        #expect(summary.autoBuffered == 0)
    }

    @Test("Zero To Budget can still carry a manual buffer and suppresses auto-buffering")
    func zeroToBudgetWithManualBuffer() {
        let summary = BudgetStore.makeEnvelopeBudgetSummary(
            availableFunds: 500,
            lastMonthOverspent: 0,
            budgeted: 500,
            toBudget: 0,
            manualBuffered: 100
        )

        #expect(summary.toBudget == 0)
        #expect(summary.forNextMonth == 0)
        #expect(summary.manualBuffered == 100)
        #expect(summary.autoBuffered == 0)
    }

    @Test("No manual or automatic buffer exposes move and hold for positive To Budget")
    func positiveToBudgetActions() {
        let summary = BudgetStore.makeEnvelopeBudgetSummary(
            availableFunds: 1_000,
            lastMonthOverspent: 0,
            budgeted: 500,
            toBudget: 500,
            manualBuffered: 0
        )

        #expect(
            EnvelopeBudgetSummaryAction.available(for: summary)
                == [.moveToCategory, .holdForNextMonth]
        )
    }

    @Test("Automatic buffer hides manual Hold")
    func automaticBufferHidesHoldAction() {
        let summary = BudgetStore.makeEnvelopeBudgetSummary(
            availableFunds: 1_500,
            lastMonthOverspent: 0,
            budgeted: 500,
            toBudget: 500,
            manualBuffered: 0
        )
        let autoBuffered = EnvelopeBudgetSummary(
            availableFunds: summary.availableFunds,
            lastMonthOverspent: summary.lastMonthOverspent,
            budgeted: summary.budgeted,
            forNextMonth: summary.forNextMonth,
            toBudget: summary.toBudget,
            manualBuffered: 0,
            autoBuffered: 500
        )

        #expect(EnvelopeBudgetSummaryAction.available(for: autoBuffered) == [.moveToCategory])
    }

    @Test("Manual buffer exposes Reset even when To Budget is zero")
    func manualBufferWithZeroToBudgetShowsReset() {
        let summary = EnvelopeBudgetSummary(
            availableFunds: 500,
            lastMonthOverspent: 0,
            budgeted: 500,
            forNextMonth: 0,
            toBudget: 0,
            manualBuffered: 100,
            autoBuffered: 0
        )

        #expect(EnvelopeBudgetSummaryAction.available(for: summary) == [.resetBuffer])
    }

    @Test("Manual buffer exposes Reset and Cover when To Budget is negative")
    func manualBufferWithNegativeToBudgetShowsResetAndCover() {
        let summary = EnvelopeBudgetSummary(
            availableFunds: 100,
            lastMonthOverspent: -200,
            budgeted: 300,
            forNextMonth: -400,
            toBudget: -100,
            manualBuffered: 50,
            autoBuffered: 0
        )

        #expect(
            EnvelopeBudgetSummaryAction.available(for: summary)
                == [.resetBuffer, .coverFromCategory]
        )
    }

    @Test("Positive To Budget with a manual buffer exposes Reset and Move but not Hold")
    func positiveToBudgetWithManualBuffer() {
        let summary = EnvelopeBudgetSummary(
            availableFunds: 1_500,
            lastMonthOverspent: 0,
            budgeted: 500,
            forNextMonth: 500,
            toBudget: 500,
            manualBuffered: 250,
            autoBuffered: 0
        )

        #expect(
            EnvelopeBudgetSummaryAction.available(for: summary)
                == [.resetBuffer, .moveToCategory]
        )
    }

    @Test("Last-month overspending ignores carryover-protected categories")
    func lastMonthOverspendingHonorsCarryoverFlag() {
        let categories = [
            CategoryBudget(
                month: "2026-08",
                categoryId: "normal",
                categoryName: "Normal",
                groupId: "group",
                groupName: "Group",
                groupSortOrder: 0,
                categorySortOrder: 0,
                budgeted: 500,
                spent: -650,
                available: -150,
                carryover: 0,
                goal: nil,
                longGoal: false,
                carryoverEnabled: false
            ),
            CategoryBudget(
                month: "2026-08",
                categoryId: "protected",
                categoryName: "Protected",
                groupId: "group",
                groupName: "Group",
                groupSortOrder: 0,
                categorySortOrder: 1,
                budgeted: 500,
                spent: -700,
                available: -200,
                carryover: 0,
                goal: nil,
                longGoal: false,
                carryoverEnabled: true
            )
        ]

        #expect(BudgetStore.lastMonthOverspent(categories) == -150)
    }

    @Test("Last-month overspending includes hidden categories")
    func lastMonthOverspendingIncludesHiddenCategories() {
        let hidden = CategoryBudget(
            month: "2026-08",
            categoryId: "hidden",
            categoryName: "Hidden",
            groupId: "group",
            groupName: "Group",
            groupSortOrder: 0,
            categorySortOrder: 0,
            budgeted: 500,
            spent: -700,
            available: -200,
            carryover: 0,
            hidden: true,
            groupHidden: true,
            goal: nil,
            longGoal: false,
            carryoverEnabled: false
        )

        #expect(BudgetStore.lastMonthOverspent([hidden]) == -200)
    }
}
