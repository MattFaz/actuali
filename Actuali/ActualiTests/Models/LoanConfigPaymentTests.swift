import Foundation
import Testing
@testable import Actuali

struct LoanConfigPaymentTests {
    /// The same $22,000 at 6% the amortization tests use, so the numbers here
    /// line up with the schedule's first row.
    private let carLoan = LoanConfig(
        originalBalance: 2_200_000,
        annualRatePercent: 6,
        minimumPayment: 36500,
        escrowOrFees: nil
    )

    private let owing = -2_200_000

    // MARK: - Splitting a payment

    @Test func paymentSplitsIntoInterestAndPrincipal() {
        let split = carLoan.paymentSplit(accountBalance: owing, payment: 36500)

        #expect(split.interest == 11000)
        #expect(split.escrow == 0)
        #expect(split.principal == 25500)
        #expect(split.interest + split.escrow + split.principal == 36500)
    }

    @Test func escrowIsTakenBeforePrincipal() {
        var mortgage = carLoan
        mortgage.escrowOrFees = 20000
        let split = mortgage.paymentSplit(accountBalance: owing, payment: 36500)

        #expect(split.interest == 11000)
        #expect(split.escrow == 20000)
        #expect(split.principal == 5500)
    }

    /// The lender charges interest on the balance whatever arrived, so
    /// underpaying shows up as negative principal — the loan grew — rather
    /// than as a quietly reduced interest charge.
    @Test func underpayingLeavesNegativePrincipalRatherThanShrinkingInterest() {
        let split = carLoan.paymentSplit(accountBalance: owing, payment: 5000)

        #expect(split.interest == 11000)
        #expect(split.principal == -6000)
    }

    @Test func aClearedLoanChargesNoInterest() {
        let split = carLoan.paymentSplit(accountBalance: 0, payment: 36500)

        #expect(split.interest == 0)
        #expect(split.principal == 36500)
    }

    // MARK: - What to offer

    @Test func payoffAmountIsTheBalancePlusThisMonthsCharges() {
        #expect(carLoan.payoffAmount(accountBalance: owing) == 2_211_000)
    }

    @Test func payoffAmountIncludesEscrow() {
        var mortgage = carLoan
        mortgage.escrowOrFees = 20000

        #expect(mortgage.payoffAmount(accountBalance: owing) == 2_231_000)
    }

    @Test func payoffAmountIsZeroOnAClearedLoan() {
        #expect(carLoan.payoffAmount(accountBalance: 0) == 0)
    }

    @Test func suggestedPaymentIsTheMinimumUntilTheLastPayment() {
        #expect(carLoan.suggestedPayment(accountBalance: owing) == 36500)
    }

    /// $200 left owing: the minimum would overshoot, so the last payment is
    /// the balance plus its own month of interest ($200 at 6% is $1.00).
    @Test func suggestedPaymentDropsToThePayoffOnTheLastOne() {
        #expect(carLoan.suggestedPayment(accountBalance: -20000) == 20100)
    }

    // MARK: - Pairing and snooze

    @Test func snoozeAppliesToItsOwnMonthOnly() {
        var config = carLoan
        config.targetSnoozedMonth = "2026-09"

        #expect(config.targetIsSnoozed(in: "2026-09"))
        #expect(!config.targetIsSnoozed(in: "2026-10"))
        #expect(!config.targetIsSnoozed(in: "2026-08"))
    }

    @Test func anUnsnoozedLoanIsNeverSnoozed() {
        #expect(!carLoan.targetIsSnoozed(in: "2026-09"))
    }

    // MARK: - Round-tripping

    @Test func pairingAndSnoozeSurviveEncoding() throws {
        var config = carLoan
        config.categoryId = "cat_car"
        config.targetSnoozedMonth = "2026-09"

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(LoanConfig.self, from: data)

        #expect(decoded == config)
    }

    /// A config written before pairing existed still decodes — the same
    /// forward compatibility `CreditCardConfig` relies on for its own later
    /// fields, and what keeps an older client's loans readable.
    @Test func aConfigWrittenBeforePairingStillDecodes() throws {
        let json = Data("""
        {"originalBalance":2200000,"annualRatePercent":6,"minimumPayment":36500}
        """.utf8)

        let decoded = try JSONDecoder().decode(LoanConfig.self, from: json)

        #expect(decoded.categoryId == nil)
        #expect(decoded.targetSnoozedMonth == nil)
        #expect(decoded.minimumPayment == 36500)
    }
}
