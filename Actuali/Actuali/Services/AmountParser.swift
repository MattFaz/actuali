import Foundation

/// Parses amounts that arrive as text from Shortcuts/Wallet automations.
///
/// Apple Wallet's transaction amount coerces to 0 when Shortcuts converts it
/// to a Number for some cards (see actuali#41, actualtap#63), but the text
/// representation carries the real value — possibly with a currency symbol,
/// currency code, and locale-specific separators ("4,00 €", "$1,234.56").
enum AmountParser {
    /// Parses using the current format when one is known. Without a format,
    /// retain the legacy separator heuristics used by automation inputs whose
    /// locale is independent of the app's selected display format.
    static func parse(_ text: String, numberFormat: ActualNumberFormat? = nil) -> Double? {
        // Exactly one number token, or refuse: shortcuts misconfigured to
        // pass the whole transaction can stringify with extra digits (dates,
        // "7-Eleven"), and a wrong amount is worse than an error.
        let tokens = text.matches(of: /-?\d[\d.,'\u{2019}\u{202F}\u{00A0}]*/)
        guard tokens.count == 1 else { return nil }

        var token = String(tokens[0].output)
        // A minus counts only if attached to the number or leading the whole
        // string — a hyphenated merchant name ("Coca-Cola") is not a sign.
        let negative = token.hasPrefix("-")
            || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-")
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "-.,'\u{2019}\u{202F}\u{00A0}"))

        if let numberFormat,
           let normalized = normalize(token, using: numberFormat),
           let value = Double(normalized) {
            return negative ? -value : value
        }

        token = token
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")

        let normalized: String
        switch (token.lastIndex(of: "."), token.lastIndex(of: ",")) {
        case let (dot?, comma?):
            // Both present: the rightmost is the decimal separator.
            let (decimal, grouping): (Character, Character) = dot > comma ? (".", ",") : (",", ".")
            normalized = token
                .replacingOccurrences(of: String(grouping), with: "")
                .replacingOccurrences(of: String(decimal), with: ".")
        case let (dot?, nil):
            normalized = resolveSingleSeparator(token, separator: ".", lastIndex: dot)
        case let (nil, comma?):
            normalized = resolveSingleSeparator(token, separator: ",", lastIndex: comma)
        case (nil, nil):
            normalized = token
        }

        guard let value = Double(normalized) else { return nil }
        return negative ? -value : value
    }

    /// Normalizes a token according to the explicitly selected Actual format.
    /// This makes an otherwise ambiguous value such as `1,234` mean 1.234 in
    /// `dot-comma`, while `1.234` remains 1,234 in that same format.
    private static func normalize(_ token: String, using numberFormat: ActualNumberFormat) -> String? {
        let decimalSeparator = Character(numberFormat.decimalSeparator)
        let groupingSeparators: Set<Character>

        switch numberFormat {
        case .commaDot, .commaDotIn:
            groupingSeparators = [","]
        case .dotComma:
            groupingSeparators = ["."]
        case .spaceComma:
            groupingSeparators = ["\u{202F}", "\u{00A0}"]
        case .apostropheDot:
            groupingSeparators = ["'", "\u{2019}"]
        }

        var seenDecimal = false
        var normalized = ""
        for character in token {
            if character == decimalSeparator {
                guard !seenDecimal else { return nil }
                seenDecimal = true
                normalized.append(".")
            } else if groupingSeparators.contains(character) {
                continue
            } else if character == "." || character == ","
                || character == "'" || character == "\u{2019}"
                || character == "\u{202F}" || character == "\u{00A0}" {
                return nil
            } else if character.isWholeNumber {
                normalized.append(character)
            } else {
                return nil
            }
        }

        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    /// With only one separator kind present, decide decimal vs grouping:
    /// repeated occurrences ("1.234.567") or a single 3-digit tail with a
    /// non-zero integer part ("1,234") mean grouping; anything else ("4,00",
    /// "4.5", "0,234") means decimal.
    private static func resolveSingleSeparator(
        _ digits: String,
        separator: Character,
        lastIndex: String.Index
    ) -> String {
        let occurrences = digits.count(where: { $0 == separator })
        let tail = digits[digits.index(after: lastIndex)...]
        let integerPart = digits[..<digits.firstIndex(of: separator)!]
        let isGrouping = occurrences > 1
            || (tail.count == 3 && !integerPart.isEmpty && integerPart != "0")
        if isGrouping {
            return digits.replacingOccurrences(of: String(separator), with: "")
        }
        return digits.replacingOccurrences(of: String(separator), with: ".")
    }
}
