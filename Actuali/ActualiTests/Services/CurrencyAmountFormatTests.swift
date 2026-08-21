import Foundation
import Testing
@testable import Actuali

/// The "Symbol Only" option (GH #83) must render the narrow symbol ("$")
/// where the standard presentation shows a locale-dependent disambiguation
/// prefix ("NZ$", "US$", "NZD "), without changing any other formatting.
struct CurrencyAmountFormatTests {

    private let enUS = Locale(identifier: "en_US")
    private let enNZ = Locale(identifier: "en_NZ")

    @Test func standardPresentationKeepsDisambiguationPrefix() {
        let formatted = CurrencyAmountFormat.string(
            cents: 123_450, currencyCode: "NZD", narrowSymbol: false, locale: enUS)
        #expect(formatted == "NZ$1,234.50")
    }

    @Test func narrowSymbolDropsPrefixForForeignCurrency() {
        let formatted = CurrencyAmountFormat.string(
            cents: 123_450, currencyCode: "NZD", narrowSymbol: true, locale: enUS)
        #expect(formatted == "$1,234.50")
    }

    /// The reporter's actual situation inverted: a NZ-locale device showing
    /// USD gets "US$"; narrow collapses it to "$" too.
    @Test func narrowSymbolDropsPrefixInForeignLocale() {
        let standard = CurrencyAmountFormat.string(
            cents: 123_450, currencyCode: "USD", narrowSymbol: false, locale: enNZ)
        let narrow = CurrencyAmountFormat.string(
            cents: 123_450, currencyCode: "USD", narrowSymbol: true, locale: enNZ)
        #expect(standard == "US$1,234.50")
        #expect(narrow == "$1,234.50")
    }

    @Test func wholeUnitsDropCents() {
        let formatted = CurrencyAmountFormat.string(
            cents: 105_150, currencyCode: "NZD", narrowSymbol: true, wholeUnits: true,
            locale: enUS)
        #expect(formatted == "$1,052")
    }

    @Test func wholeUnitsRoundPlainNumbersWithoutCurrency() {
        let formatted = CurrencyAmountFormat.string(
            cents: 105_150, currencyCode: "", narrowSymbol: false, wholeUnits: true,
            locale: enUS)
        #expect(formatted == "1,052")
    }

    @Test func budgetTableWholeUnitsUseTheSameRounding() {
        #expect(BudgetColumn.text(105_150, wholeUnits: true) == "1,052")
        #expect(BudgetColumn.text(-105_150, wholeUnits: true) == "-1,052")
        #expect(BudgetColumn.text(105_150) == "1,051.50")
    }

    /// Empty code means no currency (Actual's defaultCurrencyCode convention);
    /// narrowSymbol has nothing to narrow and must not disturb plain numbers.
    @Test func emptyCodeRendersPlainNumber() {
        let formatted = CurrencyAmountFormat.string(
            cents: 123_450, currencyCode: "", narrowSymbol: true, locale: enUS)
        #expect(formatted == "1,234.50")
    }

    /// Zero-decimal currencies keep their native precision under narrow —
    /// narrowing only changes the symbol, never the digits.
    @Test func narrowKeepsCurrencyNativePrecision() {
        let standard = CurrencyAmountFormat.string(
            cents: 123_450, currencyCode: "JPY", narrowSymbol: false, locale: enUS)
        let narrow = CurrencyAmountFormat.string(
            cents: 123_450, currencyCode: "JPY", narrowSymbol: true, locale: enUS)
        #expect(standard == "¥1,234")
        #expect(narrow == "¥1,234")
    }
}
