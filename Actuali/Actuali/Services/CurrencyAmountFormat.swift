import Foundation

/// Number formats supported by Actual's synced `numberFormat` preference.
enum ActualNumberFormat: String, CaseIterable, Identifiable, Sendable {
    case commaDot = "comma-dot"
    case dotComma = "dot-comma"
    case spaceComma = "space-comma"
    case apostropheDot = "apostrophe-dot"
    case commaDotIn = "comma-dot-in"

    var id: String {
        rawValue
    }

    var example: String {
        switch self {
        case .commaDot:
            "1,000.33"
        case .dotComma:
            "1.000,33"
        case .spaceComma:
            "1\u{202F}000,33"
        case .apostropheDot:
            "1\u{2019}000.33"
        case .commaDotIn:
            "10,00,000.33"
        }
    }

    var decimalSeparator: String {
        switch self {
        case .commaDot, .apostropheDot, .commaDotIn:
            "."
        case .dotComma, .spaceComma:
            ","
        }
    }

    private var locale: Locale {
        switch self {
        case .commaDot:
            Locale(identifier: "en_US")
        case .dotComma:
            Locale(identifier: "de_DE")
        case .spaceComma:
            Locale(identifier: "fr_FR")
        case .apostropheDot:
            Locale(identifier: "de_CH")
        case .commaDotIn:
            Locale(identifier: "en_IN")
        }
    }

    fileprivate func normalize(_ string: String) -> String {
        switch self {
        case .spaceComma:
            string.replacingOccurrences(
                of: "\u{00A0}",
                with: "\u{202F}"
            )
        case .apostropheDot:
            string.replacingOccurrences(
                of: "'",
                with: "\u{2019}"
            )
        default:
            string
        }
    }

    fileprivate func numberFormatter(
        currencyCode: String,
        wholeUnits: Bool
    ) -> NumberFormatter {
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

    private static let formatterCache = FormatterCache<NumberFormatter>()

    private func cachedString(
        from number: NSNumber,
        currencyCode: String?,
        wholeUnits: Bool
    ) -> String {
        let key = "\(rawValue)|\(currencyCode ?? "")|\(wholeUnits)"

        let formatter = Self.formatterCache.value(key) {
            if let currencyCode {
                return numberFormatter(
                    currencyCode: currencyCode,
                    wholeUnits: wholeUnits
                )
            }

            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = wholeUnits ? 0 : 2
            formatter.maximumFractionDigits = wholeUnits ? 0 : 2

            return formatter
        }

        return formatter.string(from: number) ?? ""
    }

    func format(
        number: NSNumber,
        wholeUnits: Bool,
        currencyCode: String?
    ) -> String {
        if currencyCode == nil, number.doubleValue == 0 {
            return wholeUnits
                ? "0"
                : "0\(decimalSeparator)00"
        }

        return normalize(
            cachedString(
                from: number,
                currencyCode: currencyCode,
                wholeUnits: wholeUnits
            )
        )
    }
}

enum CurrencyAmountFormat {
    /// - Parameters:
    ///   - cents: Signed amount in cents (e.g., 1050 = $10.50).
    ///   - currencyCode: ISO code; empty means no currency — amounts render
    ///     as plain numbers, matching Actual's defaultCurrencyCode convention.
    ///   - narrowSymbol: Use the narrow symbol ("$" instead of "NZ$"/"US$"),
    ///     the Settings "Symbol Only" option (GH #83).
    ///   - wholeUnits: Round to whole units, for compact chart annotations
    ///     where cents add noise.
    ///   - numberFormat: Actual's synced number format preference.
    static func string(
        cents: Int,
        currencyCode: String,
        narrowSymbol: Bool,
        wholeUnits: Bool = false,
        numberFormat: ActualNumberFormat = .commaDot,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let amount = Double(cents) / 100.0

        guard !currencyCode.isEmpty else {
            return numberFormat.format(
                number: NSNumber(value: amount),
                wholeUnits: wholeUnits,
                currencyCode: nil
            )
        }

        var style = FloatingPointFormatStyle<Double>.Currency(
            code: currencyCode,
            locale: locale
        )

        if narrowSymbol {
            style = style.presentation(.narrow)
        }

        if wholeUnits {
            style = style.precision(.fractionLength(0))
        }

        let currencyString = amount.formatted(style)

        let numericString = numberFormat
            .format(
                number: NSNumber(value: abs(amount)),
                wholeUnits: wholeUnits,
                currencyCode: currencyCode
            )
            .trimmingCharacters(in: CharacterSet.decimalDigits.inverted)

        return replacingNumericPart(
            in: currencyString,
            with: numericString
        )
    }

    private static func replacingNumericPart(
        in currencyString: String,
        with numericString: String
    ) -> String {
        let scalars = Array(currencyString.unicodeScalars)

        guard
            let firstDigit = scalars.firstIndex(
                where: { CharacterSet.decimalDigits.contains($0) }
            ),
            let lastDigit = scalars.lastIndex(
                where: { CharacterSet.decimalDigits.contains($0) }
            )
        else {
            return currencyString
        }

        let prefix = String(
            String.UnicodeScalarView(
                scalars[..<firstDigit]
            )
        )

        let suffix = String(
            String.UnicodeScalarView(
                scalars[(lastDigit + 1)...]
            )
        )

        return prefix + numericString + suffix
    }
}

/// Shared get-or-create cache for locale-keyed formatters (currency, date,
/// bundles), so call sites don't rebuild one per redraw. Keys must be
/// namespaced per call site: two sites may use the same locale yet configure
/// their cached objects differently, and must freeze a runtime locale to its
/// identifier so a cached entry can't drift when .autoupdatingCurrent follows
/// a system language change. The NSLock serializes every access to the
/// non-Sendable value dictionary, so sharing across actors is safe; handing
/// the cached value out is safe because NumberFormatter, DateFormatter and
/// Bundle use is thread-safe on iOS 7+.
final class FormatterCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Value] = [:]

    func value(_ key: String, make: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }

        if let cached = values[key] {
            return cached
        }

        let made = make()
        values[key] = made
        return made
    }
}
