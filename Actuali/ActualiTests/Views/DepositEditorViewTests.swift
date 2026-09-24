import Foundation
import Testing
@testable import Actuali

struct DepositEditorViewTests {
    // MARK: - Account picker ordering

    @Test func savingsAndInvestmentAccountsSortAboveEverythingElse() {
        #expect(DepositEditorView.typeRank(.savings) < DepositEditorView.typeRank(.checking))
        #expect(DepositEditorView.typeRank(.investment) < DepositEditorView.typeRank(.checking))
        #expect(DepositEditorView.typeRank(.savings) == DepositEditorView.typeRank(.investment))
    }

    /// Debt accounts sort last: they run the other way, so tracking one as a
    /// deposit is almost always a mistake.
    @Test func debtAccountTypesSortBelowOrdinaryAccounts() {
        #expect(DepositEditorView.typeRank(.credit) > DepositEditorView.typeRank(.checking))
        #expect(DepositEditorView.typeRank(.mortgage) > DepositEditorView.typeRank(.checking))
        #expect(DepositEditorView.typeRank(.debt) > DepositEditorView.typeRank(.checking))
    }

    // MARK: - Term parsing

    @Test func termAcceptsWholeMonths() {
        #expect(DepositEditorView.months(from: "60") == 60)
        #expect(DepositEditorView.months(from: " 24 ") == 24)
    }

    @Test func termRejectsNothingAndNonsense() {
        #expect(DepositEditorView.months(from: "") == nil)
        #expect(DepositEditorView.months(from: "abc") == nil)
        #expect(DepositEditorView.months(from: "0") == nil)
        #expect(DepositEditorView.months(from: "-12") == nil)
    }

    /// A term past the engine's ceiling clamps rather than being rejected —
    /// the curve is bounded the same way, so the two can't disagree.
    @Test func anAbsurdTermClampsToTheEngineCeiling() {
        #expect(DepositEditorView.months(from: "100000") == DepositGrowth.maxTermMonths)
    }

    // MARK: - Save validation

    private let opened = DayDate(year: 2026, month: 1, day: 15)

    @Test func buildsAConfigFromCompleteEntry() throws {
        let config = try #require(DepositEditorView.config(
            kind: .fixed,
            amount: "100000",
            rate: "7.1",
            compounding: .quarterly,
            openedOn: opened,
            term: "60"
        ))

        #expect(config.kind == .fixed)
        #expect(config.amount == 10_000_000)
        #expect(config.annualRatePercent == 7.1)
        #expect(config.compounding == .quarterly)
        #expect(config.openedOn == opened)
        #expect(config.termMonths == 60)
        #expect(config.maturityDate == DayDate(year: 2031, month: 1, day: 15))
    }

    /// A zero-interest deposit is a real if joyless thing, so a blank rate
    /// doesn't block Save.
    @Test func theRateIsOptional() throws {
        let config = try #require(DepositEditorView.config(
            kind: .recurring,
            amount: "5000",
            rate: "",
            compounding: .monthly,
            openedOn: opened,
            term: "24"
        ))

        #expect(config.annualRatePercent == 0)
        #expect(config.maturityValue == config.amount * 24)
    }

    /// Without these there is nothing to grow, so Save stays disabled.
    @Test func theAmountAndTermAreRequired() {
        #expect(DepositEditorView.config(kind: .fixed, amount: "", rate: "7", compounding: .quarterly, openedOn: opened, term: "60") == nil)
        #expect(DepositEditorView.config(kind: .fixed, amount: "0", rate: "7", compounding: .quarterly, openedOn: opened, term: "60") == nil)
        #expect(DepositEditorView.config(kind: .fixed, amount: "100000", rate: "7", compounding: .quarterly, openedOn: opened, term: "") == nil)
    }

    /// A negative rate would run the growth backwards; it clamps.
    @Test func aNegativeRateClampsToZero() throws {
        let config = try #require(DepositEditorView.config(
            kind: .fixed,
            amount: "100000",
            rate: "-5",
            compounding: .quarterly,
            openedOn: opened,
            term: "60"
        ))

        #expect(config.annualRatePercent == 0)
    }

    // MARK: - Labels

    @Test func everyCompoundingFrequencyHasItsOwnLabel() {
        let labels = DepositConfig.Compounding.allCases.map(DepositEditorView.compoundingLabel)
        // Counted outside the macro: `#expect` re-invokes a rethrowing call
        // like `contains(where:)` through a generic function value, which the
        // expansion then reads as throwing and refuses to compile.
        let blankCount = labels.filter(\.isEmpty).count

        #expect(Set(labels).count == DepositConfig.Compounding.allCases.count)
        #expect(blankCount == 0)
    }

    // MARK: - Summary row

    @Test func aRunningDepositShowsItsMaturityDate() {
        let config = DepositConfig(
            kind: .fixed, amount: 10_000_000, annualRatePercent: 7,
            compounding: .quarterly, openedOn: opened, termMonths: 60
        )
        let text = DepositSummaryRow.maturitySummary(config, on: DayDate(year: 2027, month: 6, day: 1))

        #expect(text != String(localized: "Matured"))
        #expect(text.contains("2031"))
    }

    @Test func aMaturedDepositSaysSo() {
        let config = DepositConfig(
            kind: .fixed, amount: 10_000_000, annualRatePercent: 7,
            compounding: .quarterly, openedOn: opened, termMonths: 12
        )

        #expect(DepositSummaryRow.maturitySummary(config, on: DayDate(year: 2027, month: 6, day: 1)) == String(localized: "Matured"))
    }
}
