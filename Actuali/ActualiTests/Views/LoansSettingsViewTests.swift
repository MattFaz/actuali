import Foundation
import Testing
@testable import Actuali

struct LoansSettingsViewTests {
    // MARK: - Account picker ordering

    @Test func loanAccountTypesSortAboveEverythingElse() {
        #expect(LoansSettingsView.typeRank(.mortgage) < LoansSettingsView.typeRank(.checking))
        #expect(LoansSettingsView.typeRank(.debt) < LoansSettingsView.typeRank(.savings))
        #expect(LoansSettingsView.typeRank(.mortgage) == LoansSettingsView.typeRank(.debt))
    }

    /// Cards sort last: a card tracked as a loan is almost always a mistake,
    /// and YNAB steers credit-card debt to the card type instead.
    @Test func creditCardsSortBelowOrdinaryAccounts() {
        #expect(LoansSettingsView.typeRank(.credit) > LoansSettingsView.typeRank(.checking))
    }

    // MARK: - Field round-tripping

    @Test func amountTextRoundTripsThroughCents() {
        #expect(LoansSettingsView.amountText(2_200_000) == "22000.00")
        #expect(LoansSettingsView.amountText(36500) == "365.00")
        #expect(LoansSettingsView.cents(from: "22000.00") == 2_200_000)
        #expect(LoansSettingsView.cents(from: "365") == 36500)
    }

    @Test func centsRejectsUnparseableText() {
        #expect(LoansSettingsView.cents(from: "") == nil)
        #expect(LoansSettingsView.cents(from: "abc") == nil)
    }

    /// A whole-number rate reads "6", not "6.0" — it goes straight back into
    /// the text field the user typed it in.
    @Test func rateTextTrimsTrailingZeros() {
        #expect(LoansSettingsView.rateText(6) == "6")
        #expect(LoansSettingsView.rateText(6.25) == "6.25")
        #expect(LoansSettingsView.rateText(0) == "0")
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
