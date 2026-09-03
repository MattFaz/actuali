import Foundation

/// Number formats supported by Actual's synced `numberFormat` preference.
enum ActualNumberFormat: String, CaseIterable, Identifiable, Sendable {
    case commaDot = "comma-dot"
    case dotComma = "dot-comma"
    case spaceComma = "space-comma"
    case apostropheDot = "apostrophe-dot"
    case commaDotIn = "comma-dot-in"

    var id: String { rawValue }

    var example: String {
        switch self {
        case .commaDot: return "1,000.33"
        case .dotComma: return "1.000,33"
        case .spaceComma: return "1\u{202F}000,33"
        case .apostropheDot: return "1\u{2019}000.33"
        case .commaDotIn: return "10,00,000.33"
        }
    }

    private var locale: Locale {
        switch self {
        case .commaDot: return Locale(identifier: "en_US")
        case .dotComma: return Locale(identifier: "de_DE")
        case .spaceComma: return Locale(identifier: "fr_FR")
        case .apostropheDot: return Locale(identifier: "de_CH")
        case .commaDotIn: return Locale(identifier: "en_IN")
        }
    }

    func formatter(currencyCode: String, wholeUnits: Bool) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.currencySymbol = ""
        formatter.internationalCurrencySymbol = ""
        if wholeUnits {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 0
        }
        return formatter
    }

    func decimalFormatter(wholeUnits: Bool) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = wholeUnits ? 0 : 2
        formatter.maximumFractionDigits = wholeUnits ? 0 : 2
        return formatter
    }
}

/// Shared cents → display-string formatting for the budget's display
/// currency. Used by BudgetStore's view formatting and both notification
/// composers so the "Symbol Only" setting applies everywhere amounts render.
enum CurrencyAmountFormat {

    @MainActor private static var symbolLessFormatters: [String: NumberFormatter] = [:]

    /// - Parameters:
    ///   - cents: Signed amount in cents (e.g., 1050 = $10.50).
    ///   - currencyCode: ISO code; empty means no currency — amounts render
    ///     as plain numbers, matching Actual's defaultCurrencyCode convention.
    ///   - narrowSymbol: Use the narrow symbol ("$" instead of "NZ$"/"US$"),
    ///     the Settings "Symbol Only" option (GH #83).
    ///   - wholeUnits: Round to whole units, for compact chart annotations
    ///     where cents add noise.
    ///   - numberFormat: Actual's synced number format preference.
    static func string(cents: Int, currencyCode: String, narrowSymbol: Bool,
                       wholeUnits: Bool = false,
                       numberFormat: ActualNumberFormat = .commaDot,
                       locale: Locale = .autoupdatingCurrent) -> String {
        let amount = Double(cents) / 100.0
        guard !currencyCode.isEmpty else {
            return numberFormat.decimalFormatter(wholeUnits: wholeUnits)
                .string(from: NSNumber(value: amount)) ?? ""
        }

        var style = FloatingPointFormatStyle<Double>.Currency(code: currencyCode, locale: locale)
        if narrowSymbol {
            style = style.presentation(.narrow)
        }
        if wholeUnits {
            style = style.precision(.fractionLength(0))
        }
        let currencyString = amount.formatted(style)
        let numericFormatter = numberFormat.formatter(
            currencyCode: currencyCode,
            wholeUnits: wholeUnits
        )
        let numericString = numericFormatter.string(from: NSNumber(value: amount)) ?? ""
        return replacingNumericPart(in: currencyString, with: numericString)
    }

    private static func replacingNumericPart(in currencyString: String, with numericString: String) -> String {
        let scalars = Array(currencyString.unicodeScalars)
        guard let firstDigit = scalars.firstIndex(where: { $0.properties.isNumeric }),
              let lastDigit = scalars.lastIndex(where: { $0.properties.isNumeric }) else {
            return currencyString
        }

        let prefix = String(String.UnicodeScalarView(scalars[..<firstDigit]))
        let suffix = String(String.UnicodeScalarView(scalars[(lastDigit + 1)...]))
        return prefix + numericString + suffix
    }

    /// Formats with the budget currency's native precision while omitting its
    /// symbol. The budget tables supply the currency and meaning through their
    /// column headers, leaving more horizontal room for category names.
    @MainActor
    static func symbolLessString(
        cents: Int,
        currencyCode: String,
        wholeUnits: Bool = false,
        numberFormat: ActualNumberFormat = .commaDot,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let amount = Double(cents) / 100.0
        guard !currencyCode.isEmpty else {
            return amount.formatted(
                .number.precision(.fractionLength(wholeUnits ? 0 : 2)).locale(locale)
            )
        }

        let key = "\(locale.identifier)|\(currencyCode)|\(wholeUnits)|\(numberFormat.rawValue)"
        let formatter: NumberFormatter
        if let cached = symbolLessFormatters[key] {
            formatter = cached
        } else {
            let created = numberFormat.formatter(
                currencyCode: currencyCode,
                wholeUnits: wholeUnits
            )
            symbolLessFormatters[key] = created
            formatter = created
        }

        return (formatter.string(from: NSNumber(value: amount)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2019}", with: "\u{2019}")
    }
}