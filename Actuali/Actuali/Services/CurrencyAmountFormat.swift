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

    var groupingSeparator: String {
        switch self {
        case .commaDot, .commaDotIn:
            ","
        case .dotComma:
            "."
        case .spaceComma:
            "\u{202F}"
        case .apostropheDot:
            "\u{2019}"
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

    /// Abbreviated amount for chart axes ("$400K", "$1.25M"), where a full
    /// figure costs more width than a phone chart can spare. The locale picks
    /// the abbreviation; the decimal mark follows Actual's number format.
    static func compactString(
        units: Double,
        currencyCode: String,
        narrowSymbol: Bool,
        numberFormat: ActualNumberFormat,
        locale: Locale
    ) -> String {
        // Fraction digits on the abbreviated value, not significant digits:
        // three significant digits round 250.5K to "250K", so on a narrow
        // range neighbouring ticks would share a label.
        let formatted = currencyCode.isEmpty
            ? units.formatted(
                .number.locale(locale).notation(.compactName).precision(.fractionLength(0...2))
            )
            : units.formatted(
                .currency(code: currencyCode).locale(locale)
                    .presentation(narrowSymbol ? .narrow : .standard)
                    .notation(.compactName).precision(.fractionLength(0...2))
            )
        // Only between the digits, so a "." inside a currency symbol survives.
        guard let first = formatted.firstIndex(where: \.isWholeNumber),
              let last = formatted.lastIndex(where: \.isWholeNumber)
        else { return formatted }
        // Both separators, in one pass so a swapped pair can't apply twice:
        // a language with no short form for thousands (German) writes
        // "100.000", and that "." is grouping.
        // ponytail: a separator swap, so comma-dot-in keeps western 3-digit
        // groups here rather than lakh/crore. Format the mantissa with
        // numberFormat and re-attach the suffix if that matters.
        let localeDecimal = locale.decimalSeparator ?? "."
        let localeGrouping = locale.groupingSeparator ?? ","
        let digits = formatted[first...last].map { character -> String in
            switch String(character) {
            case localeDecimal: numberFormat.decimalSeparator
            case localeGrouping: numberFormat.groupingSeparator
            default: String(character)
            }
        }.joined()
        return formatted.replacingCharacters(in: first...last, with: digits)
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
