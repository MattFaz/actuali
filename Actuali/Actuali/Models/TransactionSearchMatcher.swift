import Foundation

/// Matches transactions against the free-text query from the transactions
/// search field. Text queries match payee, category, and notes; queries that
/// parse as a currency amount also match the transaction amount, ignoring
/// sign so "12.50" finds both payments and refunds. Mirrors the Actual web
/// app: a decimal query ("12.50") requires the exact amount, while a whole
/// number ("12") matches any amount from 12.00 through 12.99.
struct TransactionSearchMatcher {
    private let query: String
    /// Exact cents to match when the query includes a decimal part.
    private let exactCents: Int?
    /// Whole-dollar value to match (truncating cents) when the query is an integer.
    private let wholeDollars: Int?

    init(_ query: String) {
        self.query = query.trimmingCharacters(in: .whitespaces)
        if let (cents, isWholeNumber) = Self.parseAmount(self.query) {
            exactCents = isWholeNumber ? nil : cents
            wholeDollars = isWholeNumber ? cents / 100 : nil
        } else {
            exactCents = nil
            wholeDollars = nil
        }
    }

    func matches(_ transaction: Transaction) -> Bool {
        if query.isEmpty {
            return true
        }
        if transaction.payeeName?.localizedCaseInsensitiveContains(query) == true ||
            transaction.categoryName?.localizedCaseInsensitiveContains(query) == true ||
            transaction.notes?.localizedCaseInsensitiveContains(query) == true {
            return true
        }
        let magnitude = abs(transaction.amount)
        if let exactCents, magnitude == exactCents {
            return true
        }
        if let wholeDollars, magnitude / 100 == wholeDollars {
            return true
        }
        return false
    }

    /// Parse the query as a currency amount, e.g. "12", "12.50", "$12.50",
    /// "-12,50". Returns the absolute value in cents, and whether the query
    /// was a whole number (no decimal separator). A separator followed by
    /// anything other than 1-2 digits (e.g. the grouping in "1,234") is
    /// ambiguous, so the query is not treated as an amount.
    private static func parseAmount(_ text: String) -> (cents: Int, isWholeNumber: Bool)? {
        var text = text
        if text.hasPrefix("-") {
            text.removeFirst()
        }
        text.removeAll(where: \.isCurrencySymbol)
        text = text.trimmingCharacters(in: .whitespaces)

        let integerPart: Substring
        let fractionPart: Substring
        if let separatorIndex = text.firstIndex(where: { $0 == "." || $0 == "," }) {
            integerPart = text[..<separatorIndex]
            fractionPart = text[text.index(after: separatorIndex)...]
            guard (1...2).contains(fractionPart.count) else { return nil }
        } else {
            integerPart = text[...]
            fractionPart = ""
        }

        let digits = integerPart + fractionPart
        guard !digits.isEmpty, digits.count <= 12,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }

        let dollars = Int(integerPart) ?? 0
        var fractionCents = Int(fractionPart) ?? 0
        if fractionPart.count == 1 {
            fractionCents *= 10
        }
        return (dollars * 100 + fractionCents, fractionPart.isEmpty)
    }
}
