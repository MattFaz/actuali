import Foundation
import Testing
@testable import Actuali

struct LoanConfigProgressTests {
    /// $22,000 at 6% APR paying $365 — the loan from YNAB's simulator.
    private let config = LoanConfig(
        originalBalance: 2_200_000,
        annualRatePercent: 6,
        minimumPayment: 36500,
        escrowOrFees: nil
    )

    /// Actual holds a loan balance negative while money is owed.
    private let owing = -1_981_000
    private let start = DayDate(year: 2022, month: 12, day: 1)

    // MARK: - Owed

    @Test func owedFlipsTheSignOfAnOwingBalance() {
        #expect(LoanConfig.owed(accountBalance: -1_981_000) == 1_981_000)
    }

    @Test func owedTreatsACreditBalanceAsNothingOwed() {
        #expect(LoanConfig.owed(accountBalance: 0) == 0)
        #expect(LoanConfig.owed(accountBalance: 5000) == 0)
    }

    // MARK: - Progress

    /// The screenshot case: $22,000 original, $19,810 still owed, 10% paid off.
    @Test func matchesTheYNABOverviewProgress() {
        #expect(config.paidOff(accountBalance: owing) == 219_000)
        #expect(abs(config.fractionPaidOff(accountBalance: owing) - 0.0995) < 0.001)
    }

    @Test func aBalanceThatGrewPastTheOriginalReadsAsNoProgress() {
        // Early on, interest can outrun payments. That is 0% paid off, not
        // a negative fraction the progress bar would render as empty-but-wrong.
        #expect(config.paidOff(accountBalance: -2_400_000) == 0)
        #expect(config.fractionPaidOff(accountBalance: -2_400_000) == 0)
    }

    @Test func anOverpaidLoanCapsAtFullyPaid() {
        #expect(config.paidOff(accountBalance: 50000) == 2_200_000)
        #expect(config.fractionPaidOff(accountBalance: 50000) == 1)
    }

    @Test func clearedLoanIsFullyPaidOff() {
        #expect(config.fractionPaidOff(accountBalance: 0) == 1)
    }

    @Test func zeroOriginalBalanceHasNoProgressRatherThanDividingByZero() {
        let blank = LoanConfig(
            originalBalance: 0,
            annualRatePercent: 6,
            minimumPayment: 36500,
            escrowOrFees: nil
        )

        #expect(blank.fractionPaidOff(accountBalance: -1000) == 0)
    }

    // MARK: - Schedule

    @Test func scheduleProjectsFromWhatIsStillOwed() throws {
        let schedule = try #require(config.schedule(accountBalance: -2_200_000, from: start))

        #expect(schedule.paymentCount == 72)
        #expect(schedule.payoffDate == DayDate(year: 2028, month: 11, day: 1))
    }

    @Test func scheduleCountsEscrowAgainstThePayment() throws {
        let withEscrow = LoanConfig(
            originalBalance: 2_200_000,
            annualRatePercent: 6,
            minimumPayment: 36500,
            escrowOrFees: 20000
        )
        let plain = try #require(config.schedule(accountBalance: -2_200_000, from: start))
        let escrowed = try #require(withEscrow.schedule(accountBalance: -2_200_000, from: start))

        #expect(escrowed.paymentCount > plain.paymentCount)
    }

    // MARK: - Summary

    @Test func payoffSummaryNamesTheMonthTheLoanClears() {
        let summary = config.payoffSummary(accountBalance: -2_200_000, from: start)

        #expect(summary.hasPrefix("Paid off "))
        #expect(summary.hasSuffix("2028"))
    }

    @Test func payoffSummaryReportsAClearedLoan() {
        #expect(config.payoffSummary(accountBalance: 0, from: start) == "Paid off")
        #expect(config.payoffSummary(accountBalance: 2500, from: start) == "Paid off")
    }

    /// A payment under the monthly interest never gets there, and saying so is
    /// more use than a blank where a date would be.
    @Test func payoffSummaryCallsOutAPaymentThatCannotClearTheLoan() {
        let underwater = LoanConfig(
            originalBalance: 2_200_000,
            annualRatePercent: 6,
            minimumPayment: 5000,
            escrowOrFees: nil
        )

        #expect(underwater.payoffSummary(accountBalance: -2_200_000, from: start)
            == "Payment doesn't cover interest")
    }
}
