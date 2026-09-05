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

    @MainActor
    @Test func budgetTableWholeUnitsUseTheSameRounding() {
        for cents in [105_150, -105_150] {
            #expect(CurrencyAmountFormat.symbolLessString(
                        cents: cents, currencyCode: "", wholeUnits: true) ==
                    CurrencyAmountFormat.string(
                        cents: cents, currencyCode: "", narrowSymbol: false,
                        wholeUnits: true, locale: enUS))
        }
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

    @Test func zeroKeepsCurrencyNativePrecision() {
        let yen = CurrencyAmountFormat.string(
            cents: 0, currencyCode: "JPY", narrowSymbol: true, locale: enUS)
        let dinar = CurrencyAmountFormat.string(
            cents: 0, currencyCode: "KWD", narrowSymbol: true, locale: enUS)
        #expect(yen == "¥0")
        #expect(dinar == "KWD 0.000")
    }

    @MainActor
    @Test func symbolLessPresentationKeepsCurrencyNativePrecision() {
        let dollars = CurrencyAmountFormat.symbolLessString(
            cents: 123_450,
            currencyCode: "USD"
        )
        let yen = CurrencyAmountFormat.symbolLessString(
            cents: 123_450,
            currencyCode: "JPY"
        )
        let dinar = CurrencyAmountFormat.symbolLessString(
            cents: 123_450,
            currencyCode: "KWD"
        )
        let roundedDollars = CurrencyAmountFormat.symbolLessString(
            cents: 123_456,
            currencyCode: "USD",
            wholeUnits: true
        )

        #expect(dollars == "1,234.50")
        #expect(yen == "1,234")
        #expect(dinar == "1,234.500")
        #expect(roundedDollars == "1,235")
    }

    @Test func actualNumberFormatsMatchExpectedGrouping() {
        #expect(CurrencyAmountFormat.string(
            cents: 100_033,
            currencyCode: "USD",
            narrowSymbol: true,
            numberFormat: .commaDot,
            locale: enUS
        ) == "$1,000.33")

        #expect(CurrencyAmountFormat.string(
            cents: 100_033,
            currencyCode: "USD",
            narrowSymbol: true,
            numberFormat: .dotComma,
            locale: enUS
        ) == "$1.000,33")

        #expect(CurrencyAmountFormat.string(
            cents: 100_033,
            currencyCode: "USD",
            narrowSymbol: true,
            numberFormat: .spaceComma,
            locale: enUS
        ) == "$1\u{202F}000,33")

        #expect(CurrencyAmountFormat.string(
            cents: 100_033,
            currencyCode: "USD",
            narrowSymbol: true,
            numberFormat: .apostropheDot,
            locale: enUS
        ) == "$1\u{2019}000.33")

        #expect(CurrencyAmountFormat.string(
            cents: 100_000_033,
            currencyCode: "USD",
            narrowSymbol: true,
            numberFormat: .commaDotIn,
            locale: enUS
        ) == "$10,00,000.33")
    }

    @Test func zeroUsesSelectedNumberFormat() {
        let expected: [(ActualNumberFormat, String)] = [
            (.commaDot, "$0.00"),
            (.dotComma, "$0,00"),
            (.spaceComma, "$0,00"),
            (.apostropheDot, "$0.00"),
            (.commaDotIn, "$0.00")
        ]

        for (format, value) in expected {
            #expect(CurrencyAmountFormat.string(
                cents: 0,
                currencyCode: "USD",
                narrowSymbol: true,
                numberFormat: format,
                locale: enUS
            ) == value)
        }
    }

    @Test func zeroWholeUnitsStaysZero() {
        for format in ActualNumberFormat.allCases {
            #expect(CurrencyAmountFormat.string(
                cents: 0,
                currencyCode: "USD",
                narrowSymbol: true,
                wholeUnits: true,
                numberFormat: format,
                locale: enUS
            ) == "$0")
        }
    }

    @Test func numberFormatRawValuesMatchActualPreferenceKeys() {
        #expect(ActualNumberFormat.allCases.map(\.rawValue) == [
            "comma-dot",
            "dot-comma",
            "space-comma",
            "apostrophe-dot",
            "comma-dot-in"
        ])
    }
}
