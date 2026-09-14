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
            toBudget: 750,
            manualBuffered: 250
        )

        #expect(summary.forNextMonth == 250)
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
            availableFunds: 600,
            lastMonthOverspent: 0,
            budgeted: 500,
            toBudget: 0,
            manualBuffered: 100
        )

        #expect(summary.toBudget == 0)
        #expect(summary.forNextMonth == 100)
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

    @Test("Holding rejects amounts above To Budget instead of clamping")
    func holdAmountValidation() {
        #expect(BudgetStore.isValidHoldAmount(300, toBudget: 300))
        #expect(BudgetStore.isValidHoldAmount(299, toBudget: 300))
        #expect(!BudgetStore.isValidHoldAmount(301, toBudget: 300))
        #expect(!BudgetStore.isValidHoldAmount(1, toBudget: 0))
    }

    @Test("Automatic buffer can be disabled")
    func automaticBufferCanBeDisabled() {
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

        #expect(
            EnvelopeBudgetSummaryAction.available(for: autoBuffered)
                == [.moveToCategory, .disableAutoBuffer]
        )
    }

    @Test("Manual buffer exposes Reset even when To Budget is zero")
    func manualBufferWithZeroToBudgetShowsReset() {
        let summary = EnvelopeBudgetSummary(
            availableFunds: 500,
            lastMonthOverspent: 0,
            budgeted: 500,
            forNextMonth: 100,
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
            forNextMonth: 50,
            toBudget: -100,
            manualBuffered: 50,
            autoBuffered: 0
        )

        #expect(
            EnvelopeBudgetSummaryAction.available(for: summary)
                == [.coverFromCategory, .resetBuffer]
        )
    }

    @Test("Positive To Budget with a manual buffer can hold more or reset")
    func positiveToBudgetWithManualBuffer() {
        let summary = EnvelopeBudgetSummary(
            availableFunds: 1_500,
            lastMonthOverspent: 0,
            budgeted: 500,
            forNextMonth: 250,
            toBudget: 500,
            manualBuffered: 250,
            autoBuffered: 0
        )

        #expect(
            EnvelopeBudgetSummaryAction.available(for: summary)
                == [.moveToCategory, .holdForNextMonth, .resetBuffer]
        )
    }
}
