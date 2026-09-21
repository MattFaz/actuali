import Testing
import Foundation
@testable import Actuali

struct LoanAmortizationTests {
    private let start = DayDate(year: 2022, month: 12, day: 1)

    // MARK: - Interest

    @Test func monthlyInterestIsTheAnnualRateOverTwelve() {
        // $22,000 at 6% APR: 22000 x 0.06 / 12 = $110.00.
        #expect(LoanAmortization.monthlyInterest(balance: 2_200_000, annualRatePercent: 6) == 11000)
    }

    @Test func monthlyInterestIsZeroWithoutRateOrBalance() {
        #expect(LoanAmortization.monthlyInterest(balance: 2_200_000, annualRatePercent: 0) == 0)
        #expect(LoanAmortization.monthlyInterest(balance: 0, annualRatePercent: 6) == 0)
        #expect(LoanAmortization.monthlyInterest(balance: -5000, annualRatePercent: 6) == 0)
    }

    // MARK: - Schedule

    /// Parity check against YNAB's own Loan Payoff Simulator, which for a
    /// $22,000 balance at 6% APR paying $365/month reports 72 payments
    /// remaining and $4,245.66 of interest. Monthly rounding puts us 7c away,
    /// which is the whole tolerance this model has to offer — YNAB rounds the
    /// same interest charge to the cent every month too.
    @Test func matchesYNABLoanPayoffSimulator() throws {
        let schedule = try #require(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: 36500, startingMonth: start))

        #expect(schedule.paymentCount == 72)
        #expect(schedule.totalInterest == 424_573)
        #expect(abs(schedule.totalInterest - 424_566) <= 10)
        #expect(schedule.payoffDate == DayDate(year: 2028, month: 11, day: 1))
    }

    @Test func finalPaymentClearsTheBalanceExactly() throws {
        let schedule = try #require(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: 36500, startingMonth: start))
        let last = try #require(schedule.entries.last)

        #expect(last.balance == 0)
        // The loan runs out mid-payment, so the last one is a part payment.
        #expect(last.payment == 33073)
        #expect(last.payment < 36500)
    }

    @Test func interestFallsAsPrincipalIsRepaid() throws {
        let schedule = try #require(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: 36500, startingMonth: start))
        let first = try #require(schedule.entries.first)
        let last = try #require(schedule.entries.last)

        #expect(first.interest > last.interest)
        #expect(first.principal < last.principal)
        #expect(first.interest == 11000)
        #expect(first.principal == 36500 - 11000)
    }

    @Test func monthsAdvanceOneAtATime() throws {
        let schedule = try #require(LoanAmortization.schedule(
            balance: 500_000, annualRatePercent: 5, payment: 50000, startingMonth: start))

        #expect(schedule.entries.first?.month == start)
        #expect(schedule.entries[1].month == DayDate(year: 2023, month: 1, day: 1))
    }

    @Test func zeroRateLoanDividesEvenly() throws {
        let schedule = try #require(LoanAmortization.schedule(
            balance: 120_000, annualRatePercent: 0, payment: 10000, startingMonth: start))

        #expect(schedule.paymentCount == 12)
        #expect(schedule.totalInterest == 0)
        #expect(schedule.totalPaid == 120_000)
    }

    @Test func clearedBalanceHasNothingToSchedule() throws {
        let schedule = try #require(LoanAmortization.schedule(
            balance: 0, annualRatePercent: 6, payment: 36500, startingMonth: start))

        #expect(schedule.entries.isEmpty)
        #expect(schedule.payoffDate == nil)
        #expect(schedule.totalInterest == 0)
    }

    // MARK: - Payments that never get there

    @Test func paymentCoveringOnlyInterestNeverAmortizes() {
        // $110.00 is exactly one month's interest on $22,000 at 6%.
        #expect(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: 11000, startingMonth: start) == nil)
    }

    @Test func paymentBelowInterestNeverAmortizes() {
        #expect(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: 5000, startingMonth: start) == nil)
    }

    // MARK: - Escrow

    @Test func escrowIsCoveredBeforePrincipal() throws {
        let schedule = try #require(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: 36500,
            escrowOrFees: 20000, startingMonth: start))
        let first = try #require(schedule.entries.first)

        #expect(first.escrow == 20000)
        #expect(first.interest == 11000)
        #expect(first.principal == 36500 - 11000 - 20000)
    }

    @Test func escrowCanStallALoanThatWouldOtherwiseAmortize() {
        // A $310 payment would chip away at this loan on its own, but $200 of
        // escrow on top of $110 of interest consumes all of it.
        #expect(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: 31000,
            escrowOrFees: 20000, startingMonth: start) == nil)
    }

    // MARK: - One-off extra payments

    @Test func oneTimeExtraPaymentShortensTheLoan() throws {
        let baseline = try #require(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: 36500, startingMonth: start))
        let boosted = try #require(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: 36500,
            extraPayments: [start: 500_000], startingMonth: start))

        #expect(boosted.paymentCount == 54)
        #expect(boosted.paymentCount < baseline.paymentCount)
        #expect(boosted.totalInterest == 243_389)
        #expect(boosted.totalInterest < baseline.totalInterest)
    }

    @Test func extraPaymentAppliesOnlyToItsOwnMonth() throws {
        let schedule = try #require(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: 36500,
            extraPayments: [start: 500_000], startingMonth: start))

        #expect(schedule.entries[0].payment == 36500 + 500_000)
        #expect(schedule.entries[1].payment == 36500)
    }

    // MARK: - Solving for a payment

    @Test func requiredPaymentIsTheSmallestThatMeetsTheTerm() throws {
        let payment = try #require(LoanAmortization.requiredPayment(
            balance: 2_200_000, annualRatePercent: 6, months: 72, startingMonth: start))

        #expect(payment == 36461)
        let onTime = try #require(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: payment, startingMonth: start))
        #expect(onTime.paymentCount == 72)

        // One cent less misses the term, which is what makes it the smallest.
        let short = try #require(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: payment - 1, startingMonth: start))
        #expect(short.paymentCount == 73)
    }

    @Test func requiredPaymentHandlesAZeroRateLoan() {
        #expect(LoanAmortization.requiredPayment(
            balance: 120_000, annualRatePercent: 0, months: 12, startingMonth: start) == 10000)
    }

    @Test func requiredPaymentIncludesEscrow() throws {
        let payment = try #require(LoanAmortization.requiredPayment(
            balance: 120_000, annualRatePercent: 0, escrowOrFees: 5000,
            months: 12, startingMonth: start))

        #expect(payment == 15000)
    }

    @Test func requiredPaymentRejectsATermItCannotHonour() {
        #expect(LoanAmortization.requiredPayment(
            balance: 2_200_000, annualRatePercent: 6, months: 0, startingMonth: start) == nil)
        #expect(LoanAmortization.requiredPayment(
            balance: 2_200_000, annualRatePercent: 6,
            months: LoanAmortization.maxMonths + 1, startingMonth: start) == nil)
    }

    @Test func requiredPaymentIsZeroForAClearedBalance() {
        #expect(LoanAmortization.requiredPayment(
            balance: 0, annualRatePercent: 6, months: 12, startingMonth: start) == 0)
    }

    // MARK: - Savings

    @Test func savingsReportsInterestAndTimeSaved() throws {
        let minimum = try #require(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: 36500, startingMonth: start))
        let target = try #require(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: 46500, startingMonth: start))

        let savings = LoanAmortization.savings(minimum: minimum, target: target)
        #expect(savings.interest == 108_035)
        #expect(savings.months == 17)
    }

    @Test func savingsNeverGoesNegative() throws {
        let minimum = try #require(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: 46500, startingMonth: start))
        let target = try #require(LoanAmortization.schedule(
            balance: 2_200_000, annualRatePercent: 6, payment: 36500, startingMonth: start))

        let savings = LoanAmortization.savings(minimum: minimum, target: target)
        #expect(savings.interest == 0)
        #expect(savings.months == 0)
    }
}
