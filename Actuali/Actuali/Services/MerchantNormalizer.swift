import Foundation

/// Strips common payment-processor prefixes and store-number suffixes from raw
/// Apple Pay / Wallet merchant strings, producing a normalized payee name.
///
/// Pure function — no I/O, no state.
enum MerchantNormalizer {
    /// Leading prefixes to strip, case-insensitive.
    private static let leadingPrefixes: [String] = [
        "SQ *",
        "TST*",
        "TST *",
        "SP ",
        "PAYPAL *"
    ]

    /// Trailing store-number pattern: a space, `#`, then one or more digits, to end of string.
    private static let trailingStoreNumberRegex: NSRegularExpression = // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\s+#\d+\s*$"#, options: [])

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)

        // Strip leading prefix (first match wins; case-insensitive).
        for prefix in leadingPrefixes {
            if s.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
                s = String(s.dropFirst(prefix.count))
                s = s.trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Strip trailing store number.
        let nsRange = NSRange(s.startIndex..., in: s)
        s = trailingStoreNumberRegex.stringByReplacingMatches(
            in: s, options: [], range: nsRange, withTemplate: ""
        )

        s = s.trimmingCharacters(in: .whitespaces)
        return s.localizedCapitalized
    }
}
