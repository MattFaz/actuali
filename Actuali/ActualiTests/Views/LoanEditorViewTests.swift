import Foundation
import Testing
@testable import Actuali

struct LoanEditorViewTests {
    // MARK: - Account picker ordering

    @Test func loanAccountTypesSortAboveEverythingElse() {
        #expect(LoanEditorView.typeRank(.mortgage) < LoanEditorView.typeRank(.checking))
        #expect(LoanEditorView.typeRank(.debt) < LoanEditorView.typeRank(.savings))
        #expect(LoanEditorView.typeRank(.mortgage) == LoanEditorView.typeRank(.debt))
    }

    /// Cards sort last: a card tracked as a loan is almost always a mistake,
    /// and YNAB steers credit-card debt to the card type instead.
    @Test func creditCardsSortBelowOrdinaryAccounts() {
        #expect(LoanEditorView.typeRank(.credit) > LoanEditorView.typeRank(.checking))
    }

    // MARK: - Field round-tripping

    @Test func amountTextRoundTripsThroughCents() {
        #expect(LoanEditorView.amountText(2_200_000) == "22000.00")
        #expect(LoanEditorView.amountText(36500) == "365.00")
        #expect(LoanEditorView.cents(from: "22000.00") == 2_200_000)
        #expect(LoanEditorView.cents(from: "365") == 36500)
    }

    @Test func centsRejectsUnparseableText() {
        #expect(LoanEditorView.cents(from: "") == nil)
        #expect(LoanEditorView.cents(from: "abc") == nil)
    }

    /// A whole-number rate reads "6", not "6.0" — it goes straight back into
    /// the text field the user typed it in.
    @Test func rateTextTrimsTrailingZeros() {
        #expect(LoanEditorView.rateText(6) == "6")
        #expect(LoanEditorView.rateText(6.25) == "6.25")
        #expect(LoanEditorView.rateText(0) == "0")
    }

    // MARK: - Save validation

    @Test func buildsAConfigFromCompleteEntry() throws {
        let config = try #require(LoanEditorView.config(
            originalBalance: "22000",
            rate: "6.25",
            payment: "365",
            escrow: "200"
        ))

        #expect(config.originalBalance == 2_200_000)
        #expect(config.annualRatePercent == 6.25)
        #expect(config.minimumPayment == 36500)
        #expect(config.escrowOrFees == 20000)
    }

    /// A 0% family loan is real, and escrow only applies to mortgages, so
    /// neither blocks Save.
    @Test func rateAndEscrowAreOptional() throws {
        let config = try #require(LoanEditorView.config(
            originalBalance: "22000",
            rate: "",
            payment: "365",
            escrow: ""
        ))

        #expect(config.annualRatePercent == 0)
        #expect(config.escrowOrFees == nil)
    }

    /// Without these the projection is meaningless, so Save stays disabled.
    @Test func balanceAndPaymentAreRequired() {
        #expect(LoanEditorView.config(originalBalance: "", rate: "6", payment: "365", escrow: "") == nil)
        #expect(LoanEditorView.config(originalBalance: "22000", rate: "6", payment: "", escrow: "") == nil)
        #expect(LoanEditorView.config(originalBalance: "0", rate: "6", payment: "365", escrow: "") == nil)
        #expect(LoanEditorView.config(originalBalance: "22000", rate: "6", payment: "0", escrow: "") == nil)
    }

    @Test func aZeroEscrowIsStoredAsNoEscrow() throws {
        let config = try #require(LoanEditorView.config(
            originalBalance: "22000",
            rate: "6",
            payment: "365",
            escrow: "0"
        ))

        #expect(config.escrowOrFees == nil)
    }

    /// A negative rate would make the amortization run backwards; it clamps.
    @Test func aNegativeRateClampsToZero() throws {
        let config = try #require(LoanEditorView.config(
            originalBalance: "22000",
            rate: "-5",
            payment: "365",
            escrow: ""
        ))

        #expect(config.annualRatePercent == 0)
    }

    // MARK: - Progress label

    @Test func progressTextReadsAsAPercentagePaidOff() {
        let text = LoanSummaryRow.progressText(0.1)

        #expect(text.hasSuffix(" Paid Off"))
        #expect(text.contains("10"))
    }

    /// Exactly-representable fractions only: a value like 0.0995 lands on a
    /// rounding boundary that binary floating point resolves either way.
    @Test func percentTextCapsAtOneFractionDigit() {
        let en = Locale(identifier: "en_US")

        #expect(LoanSummaryRow.percentText(0, locale: en) == "0%")
        #expect(LoanSummaryRow.percentText(1, locale: en) == "100%")
        #expect(LoanSummaryRow.percentText(0.5, locale: en) == "50%")
        #expect(LoanSummaryRow.percentText(0.125, locale: en) == "12.5%")
    }
}
