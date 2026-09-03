import Foundation

/// Shared cents → display-string formatting for the budget's display
/// currency. Used by BudgetStore's view formatting and both notification
/// composers so the "Symbol Only" setting applies everywhere amounts render.
enum CurrencyAmountFormat {

    /// - Parameters:
    ///   - cents: Signed amount in cents (e.g., 1050 = $10.50).
    ///   - currencyCode: ISO code; empty means no currency — amounts render
    ///     as plain numbers, matching Actual's defaultCurrencyCode convention.
    ///   - narrowSymbol: Use the narrow symbol ("$" instead of "NZ$"/"US$"),
    ///     the Settings "Symbol Only" option (GH #83).
    ///   - wholeUnits: Round to whole units, for compact chart annotations
    ///     where cents add noise.
    static func string(cents: Int, currencyCode: String, narrowSymbol: Bool,
                       wholeUnits: Bool = false,
                       locale: Locale = .autoupdatingCurrent) -> String {
        let amount = Double(cents) / 100.0
        guard !currencyCode.isEmpty else {
            return amount.formatted(
                .number.precision(.fractionLength(wholeUnits ? 0 : 2)).locale(locale))
        }
        var style = FloatingPointFormatStyle<Double>.Currency(code: currencyCode, locale: locale)
        if narrowSymbol {
            style = style.presentation(.narrow)
        }
        if wholeUnits {
            style = style.precision(.fractionLength(0))
        }
        return amount.formatted(style)
    }
}
