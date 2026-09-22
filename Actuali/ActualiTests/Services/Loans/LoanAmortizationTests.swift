import Foundation
import Testing
@testable import Actuali

struct LoanAmortizationTests {
    private let start = DayDate(year: 2022, month: 12, day: 1)

    /// The loan from YNAB's Loan Payoff Simulator: $22,000 owed at 6% APR.
    /// Most cases below vary only the payment, so they share it.
    private func carLoan(
        payment: Int,
        escrow: Int = 0,
        extras: [DayDate: Int] = [:]
    ) -> LoanAmortization.Schedule? {
        LoanAmortization.schedule(
            balance: 2_200_000,
            annualRatePercent: 6,
            payment: payment,
            escrowOrFees: escrow,
            extraPayments: extras,
            startingMonth: start
        )
    }

    /// Smallest payment clearing the same loan within `months`.
    private func carLoanPayment(months: Int) -> Int? {
        LoanAmortization.requiredPayment(
            balance: 2_200_000,
            annualRatePercent: 6,
            months: months,
            startingMonth: start
        )
    }

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

    /// Parity check against YNAB's own Loan Payoff Simulator, which for this
    /// loan paying $365/month reports 72 payments remaining, a Nov 2028 payoff
    /// and $4,245.66 of interest. Monthly rounding puts us 7c away, which is
    /// the whole tolerance this model has to offer — YNAB rounds the same
    /// interest charge to the cent every month too.
    @Test func matchesYNABLoanPayoffSimulator() throws {
        let schedule = try #require(carLoan(payment: 36500))

        #expect(schedule.paymentCount == 72)
        #expect(schedule.totalInterest == 424_573)
        #expect(abs(schedule.totalInterest - 424_566) <= 10)
        #expect(schedule.payoffDate == DayDate(year: 2028, month: 11, day: 1))
    }

    @Test func finalPaymentClearsTheBalanceExactly() throws {
        let schedule = try #require(carLoan(payment: 36500))
        let last = try #require(schedule.entries.last)

        #expect(last.balance == 0)
        // The loan runs out mid-payment, so the last one is a part payment.
        #expect(last.payment == 33073)
        #expect(last.payment < 36500)
    }

    @Test func interestFallsAsPrincipalIsRepaid() throws {
        let schedule = try #require(carLoan(payment: 36500))
        let first = try #require(schedule.entries.first)
        let last = try #require(schedule.entries.last)

        #expect(first.interest > last.interest)
        #expect(first.principal < last.principal)
        #expect(first.interest == 11000)
        #expect(first.principal == 36500 - 11000)
    }

    @Test func monthsAdvanceOneAtATime() throws {
        let schedule = try #require(carLoan(payment: 36500))

        #expect(schedule.entries.first?.month == start)
        #expect(schedule.entries[1].month == DayDate(year: 2023, month: 1, day: 1))
    }

    @Test func zeroRateLoanDividesEvenly() throws {
        let schedule = try #require(LoanAmortization.schedule(
            balance: 120_000,
            annualRatePercent: 0,
            payment: 10000,
            startingMonth: start
        ))

        #expect(schedule.paymentCount == 12)
        #expect(schedule.totalInterest == 0)
        #expect(schedule.totalPaid == 120_000)
    }

    @Test func clearedBalanceHasNothingToSchedule() throws {
        let cleared = try #require(LoanAmortization.schedule(
            balance: 0,
            annualRatePercent: 6,
            payment: 36500,
            startingMonth: start
        ))

        #expect(cleared.entries.isEmpty)
        #expect(cleared.payoffDate == nil)
        #expect(cleared.totalInterest == 0)
    }

    // MARK: - Payments that never get there

    @Test func paymentCoveringOnlyInterestNeverAmortizes() {
        // $110.00 is exactly one month's interest on $22,000 at 6%.
        #expect(carLoan(payment: 11000) == nil)
    }

    @Test func paymentBelowInterestNeverAmortizes() {
        #expect(carLoan(payment: 5000) == nil)
    }

    // MARK: - Escrow

    @Test func escrowIsCoveredBeforePrincipal() throws {
        let schedule = try #require(carLoan(payment: 36500, escrow: 20000))
        let first = try #require(schedule.entries.first)

        #expect(first.escrow == 20000)
        #expect(first.interest == 11000)
        #expect(first.principal == 36500 - 11000 - 20000)
    }

    @Test func escrowCanStallALoanThatWouldOtherwiseAmortize() {
        // A $310 payment would chip away at this loan on its own, but $200 of
        // escrow on top of $110 of interest consumes all of it.
        #expect(carLoan(payment: 31000, escrow: 20000) == nil)
    }

    // MARK: - One-off extra payments

    @Test func oneTimeExtraPaymentShortensTheLoan() throws {
        let baseline = try #require(carLoan(payment: 36500))
        let boosted = try #require(carLoan(payment: 36500, extras: [start: 500_000]))

        #expect(boosted.paymentCount == 54)
        #expect(boosted.paymentCount < baseline.paymentCount)
        #expect(boosted.totalInterest == 243_389)
        #expect(boosted.totalInterest < baseline.totalInterest)
    }

    @Test func extraPaymentAppliesOnlyToItsOwnMonth() throws {
        let schedule = try #require(carLoan(payment: 36500, extras: [start: 500_000]))

        #expect(schedule.entries[0].payment == 36500 + 500_000)
        #expect(schedule.entries[1].payment == 36500)
    }

    // MARK: - Solving for a payment

    @Test func requiredPaymentIsTheSmallestThatMeetsTheTerm() throws {
        let payment = try #require(carLoanPayment(months: 72))
        #expect(payment == 36461)

        let onTime = try #require(carLoan(payment: payment))
        #expect(onTime.paymentCount == 72)

        // One cent less misses the term, which is what makes it the smallest.
        let short = try #require(carLoan(payment: payment - 1))
        #expect(short.paymentCount == 73)
    }

    @Test func requiredPaymentHandlesAZeroRateLoan() {
        let payment = LoanAmortization.requiredPayment(
            balance: 120_000,
            annualRatePercent: 0,
            months: 12,
            startingMonth: start
        )

        #expect(payment == 10000)
    }

    @Test func requiredPaymentIncludesEscrow() {
        let payment = LoanAmortization.requiredPayment(
            balance: 120_000,
            annualRatePercent: 0,
            escrowOrFees: 5000,
            months: 12,
            startingMonth: start
        )

        #expect(payment == 15000)
    }

    @Test func requiredPaymentRejectsATermItCannotHonour() {
        #expect(carLoanPayment(months: 0) == nil)
        #expect(carLoanPayment(months: LoanAmortization.maxMonths + 1) == nil)
    }

    @Test func requiredPaymentIsZeroForAClearedBalance() {
        let payment = LoanAmortization.requiredPayment(
            balance: 0,
            annualRatePercent: 6,
            months: 12,
            startingMonth: start
        )

        #expect(payment == 0)
    }

    // MARK: - Savings

    @Test func savingsReportsInterestAndTimeSaved() throws {
        let minimum = try #require(carLoan(payment: 36500))
        let target = try #require(carLoan(payment: 46500))

        let savings = LoanAmortization.savings(minimum: minimum, target: target)
        #expect(savings.interest == 108_035)
        #expect(savings.months == 17)
    }

    @Test func savingsNeverGoesNegative() throws {
        let minimum = try #require(carLoan(payment: 46500))
        let target = try #require(carLoan(payment: 36500))

        let savings = LoanAmortization.savings(minimum: minimum, target: target)
        #expect(savings.interest == 0)
        #expect(savings.months == 0)
    }
}
