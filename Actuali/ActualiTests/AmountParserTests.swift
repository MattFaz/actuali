import Testing
@testable import Actuali

struct AmountParserTests {

    @Test func parsesPlainDecimal() {
        #expect(AmountParser.parse("4.00") == 4.0)
        #expect(AmountParser.parse("4.5") == 4.5)
        #expect(AmountParser.parse("12") == 12.0)
    }

    @Test func parsesCommaDecimal() {
        #expect(AmountParser.parse("4,00") == 4.0)
        #expect(AmountParser.parse("4,5") == 4.5)
    }

    @Test func stripsCurrencySymbolsAndCodes() {
        #expect(AmountParser.parse("$4.00") == 4.0)
        #expect(AmountParser.parse("4,00 €") == 4.0)
        #expect(AmountParser.parse("CHF 12.50") == 12.5)
        #expect(AmountParser.parse("4.00 USD") == 4.0)
        #expect(AmountParser.parse("£1,234.56") == 1234.56)
    }

    @Test func parsesGroupedThousands() {
        #expect(AmountParser.parse("1,234.56") == 1234.56)
        #expect(AmountParser.parse("1.234,56") == 1234.56)
        #expect(AmountParser.parse("1,234,567.89") == 1234567.89)
    }

    @Test func treatsSingleSeparatorWithThreeDigitTailAsGrouping() {
        #expect(AmountParser.parse("1,234") == 1234.0)
        #expect(AmountParser.parse("1.234.567") == 1234567.0)
    }

    @Test func treatsZeroIntegerPartAsDecimal() {
        #expect(AmountParser.parse("0,234") == 0.234)
        #expect(AmountParser.parse("0.50") == 0.5)
    }

    @Test func parsesNegativeAmounts() {
        #expect(AmountParser.parse("-4.00") == -4.0)
        #expect(AmountParser.parse("-$4.00") == -4.0)
    }

    @Test func parsesZero() {
        #expect(AmountParser.parse("0") == 0.0)
        #expect(AmountParser.parse("0.00") == 0.0)
    }

    @Test func trimsWhitespace() {
        #expect(AmountParser.parse("  4.00  ") == 4.0)
    }

    @Test func parsesSingleAmountEmbeddedInText() {
        #expect(AmountParser.parse("Starbucks $4.50") == 4.5)
        #expect(AmountParser.parse("Betrag: 4,00.") == 4.0)
    }

    @Test func hyphenInSurroundingTextIsNotANegativeSign() {
        #expect(AmountParser.parse("Coca-Cola $4.00") == 4.0)
    }

    @Test func rejectsTextWithMultipleNumbers() {
        #expect(AmountParser.parse("7-Eleven $4.50") == nil)
        #expect(AmountParser.parse("Jan 5 2026 $4.00") == nil)
    }

    @Test func rejectsEmptyAndNonNumericInput() {
        #expect(AmountParser.parse("") == nil)
        #expect(AmountParser.parse("   ") == nil)
        #expect(AmountParser.parse("abc") == nil)
        #expect(AmountParser.parse("$") == nil)
    }
}
