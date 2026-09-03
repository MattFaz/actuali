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

    @Test func selectedCommaDotTreatsCommaAsGrouping() {
        #expect(AmountParser.parse("1,234", numberFormat: .commaDot) == 1234.0)
        #expect(AmountParser.parse("1,234.56", numberFormat: .commaDot) == 1234.56)
        #expect(AmountParser.parse("10,00,000.33", numberFormat: .commaDot) == 1000000.33)
    }

    @Test func selectedDotCommaTreatsCommaAsDecimal() {
        #expect(AmountParser.parse("1,234", numberFormat: .dotComma) == 1.234)
        #expect(AmountParser.parse("1.234,56", numberFormat: .dotComma) == 1234.56)
        #expect(AmountParser.parse("1,23", numberFormat: .dotComma) == 1.23)
    }

    @Test func selectedSpaceCommaTreatsNarrowSpaceAsGrouping() {
        #expect(AmountParser.parse("1\u{202F}234,56", numberFormat: .spaceComma) == 1234.56)
        #expect(AmountParser.parse("1\u{00A0}234,56", numberFormat: .spaceComma) == 1234.56)
    }

    @Test func selectedApostropheDotTreatsApostropheAsGrouping() {
        #expect(AmountParser.parse("1\u{2019}234.56", numberFormat: .apostropheDot) == 1234.56)
        #expect(AmountParser.parse("1'234.56", numberFormat: .apostropheDot) == 1234.56)
    }

    @Test func selectedIndianFormatUsesIndianGrouping() {
        #expect(AmountParser.parse("12,34,567.89", numberFormat: .commaDotIn) == 1234567.89)
        #expect(AmountParser.parse("1,234.56", numberFormat: .commaDotIn) == 1234.56)
    }

    @Test func selectedFormatRejectsConflictingSeparatorsInsteadOfGuessing() {
        #expect(AmountParser.parse("1,234.56", numberFormat: .dotComma) == nil)
        #expect(AmountParser.parse("1.234,56", numberFormat: .commaDot) == nil)
        #expect(AmountParser.parse("1'234,56", numberFormat: .dotComma) == nil)
        #expect(AmountParser.parse("1.234.56", numberFormat: .apostropheDot) == nil)
    }

    @Test func selectedFormatPreservesZeroAndNegativeValues() {
        #expect(AmountParser.parse("0,00", numberFormat: .dotComma) == 0.0)
        #expect(AmountParser.parse("-1.234,56", numberFormat: .dotComma) == -1234.56)
        #expect(AmountParser.parse("-1\u{2019}234.56", numberFormat: .apostropheDot) == -1234.56)
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
