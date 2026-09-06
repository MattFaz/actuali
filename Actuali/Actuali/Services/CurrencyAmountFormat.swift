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
        case .commaDot:
            return "1,000.33"
        case .dotComma:
            return "1.000,33"
        case .spaceComma:
            return "1\u{202F}000,33"
        case .apostropheDot:
            return "1\u{2019}000.33"
        case .commaDotIn:
            return "10,00,000.33"
        }
    }

    var decimalSeparator: String {
        switch self {
        case .commaDot, .apostropheDot, .commaDotIn:
            return "."
        case .dotComma, .spaceComma:
            return ","
        }
    }

    private var locale: Locale {
        switch self {
        case .commaDot:
            return Locale(identifier: "en_US")
        case .dotComma:
            return Locale(identifier: "de_DE")
        case .spaceComma:
            return Locale(identifier: "fr_FR")
        case .apostropheDot:
            return Locale(identifier: "de_CH")
        case .commaDotIn:
            return Locale(identifier: "en_IN")
        }
    }

    fileprivate func normalize(_ string: String) -> String {
        switch self {
        case .spaceComma:
            return string.replacingOccurrences(
                of: "\u{00A0}",
                with: "\u{202F}"
            )
        case .apostropheDot:
            return string.replacingOccurrences(
                of: "'",
                with: "\u{2019}"
            )
        default:
            return string
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
     /// The NSLock serializes every access to the non-Sendable NumberFormatter
     /// dictionary (and each format call), so sharing across actors is safe.
    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [String: NumberFormatter] = [:]

        func string(
            from number: NSNumber,
            key: String,
            makeFormatter: () -> NumberFormatter
        ) -> String {
            lock.lock()
            defer { lock.unlock() }

            let formatter: NumberFormatter

            if let cached = formatters[key] {
                formatter = cached
            } else {
                formatter = makeFormatter()
                formatters[key] = formatter
            }

            return formatter.string(from: number) ?? ""
        }
    }

    private static let formatterCache = FormatterCache()

    private func cachedString(
        from number: NSNumber,
        currencyCode: String?,
        wholeUnits: Bool
    ) -> String {
        let key = "\(rawValue)|\(currencyCode ?? "")|\(wholeUnits)"

        return Self.formatterCache.string(from: number, key: key) {
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
    }

    func format(
        number: NSNumber,
        wholeUnits: Bool,
        currencyCode: String?
    ) -> String {
        if currencyCode == nil && number.doubleValue == 0 {
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
    @MainActor
    private static var symbolLessFormatters: [String: NumberFormatter] = [:]

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

    /// Formats with the budget currency's native precision while omitting its
    /// symbol. The budget tables supply the currency and meaning through their
    /// column headers, leaving more horizontal room for category names.
    @MainActor
    static func symbolLessString(
        cents: Int,
        currencyCode: String,
        wholeUnits: Bool = false,
        numberFormat: ActualNumberFormat = .commaDot
    ) -> String {
        let amount = Double(cents) / 100.0

        guard !currencyCode.isEmpty else {
            return numberFormat.format(
                number: NSNumber(value: amount),
                wholeUnits: wholeUnits,
                currencyCode: nil
            )
        }

        let key = "\(currencyCode)|\(wholeUnits)|\(numberFormat.rawValue)"

        let formatter: NumberFormatter

        if let cached = symbolLessFormatters[key] {
            formatter = cached
        } else {
            let created = numberFormat.numberFormatter(
                currencyCode: currencyCode,
                wholeUnits: wholeUnits
            )

            symbolLessFormatters[key] = created
            formatter = created
        }

        return numberFormat
            .normalize(
                formatter.string(
                    from: NSNumber(value: amount)
                ) ?? ""
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
