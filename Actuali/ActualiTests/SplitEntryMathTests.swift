import Testing
@testable import Actuali

struct SplitEntryMathTests {
    @Test func blankLinesCountAsZero() {
        #expect(SplitEntryMath.remainingCents(total: "100", lineAmounts: ["20", "", "30.50"]) == 4950)
    }

    @Test func allBlankLinesLeaveFullTotal() {
        #expect(SplitEntryMath.remainingCents(total: "62.18", lineAmounts: ["", ""]) == 6218)
    }

    @Test func zeroWhenFullyAssigned() {
        #expect(SplitEntryMath.remainingCents(total: "50", lineAmounts: ["20", "30"]) == 0)
    }

    @Test func negativeWhenOverAssigned() {
        #expect(SplitEntryMath.remainingCents(total: "50", lineAmounts: ["60"]) == -1000)
    }

    @Test func nilWhileTotalDoesNotParse() {
        #expect(SplitEntryMath.remainingCents(total: "", lineAmounts: ["20"]) == nil)
        #expect(SplitEntryMath.remainingCents(total: "abc", lineAmounts: ["20"]) == nil)
    }

    @Test func nilWhenNonBlankLineDoesNotParse() {
        #expect(SplitEntryMath.remainingCents(total: "100", lineAmounts: ["1.2.3"]) == nil)
    }

    @Test func negativeLinesGiveBackTheirAmount() {
        // A refund line inside an expense split enlarges the remainder
        // instead of consuming it (GH #216).
        #expect(SplitEntryMath.remainingCents(total: "20", lineAmounts: ["30", "-10"]) == 0)
    }

    @Test func relativeAmountStringSignsAgainstParentDirection() {
        // Children matching the parent's direction load unsigned; opposite
        // ones load negative so plan()'s sign flip round-trips them (GH #216).
        #expect(SplitEntryMath.relativeAmountString(childCents: -3000, parentCents: -2000) == "30.00")
        #expect(SplitEntryMath.relativeAmountString(childCents: 1000, parentCents: -2000) == "-10.00")
        #expect(SplitEntryMath.relativeAmountString(childCents: 600, parentCents: 1000) == "6.00")
        #expect(SplitEntryMath.relativeAmountString(childCents: -400, parentCents: 1000) == "-4.00")
    }

    @Test func amountStringMatchesFieldFormat() {
        #expect(SplitEntryMath.amountString(fromCents: 4950) == "49.50")
        #expect(SplitEntryMath.amountString(fromCents: 5) == "0.05")
        #expect(SplitEntryMath.amountString(fromCents: 100) == "1.00")
        #expect(SplitEntryMath.amountString(fromCents: 1234) == "12.34")
    }
}
