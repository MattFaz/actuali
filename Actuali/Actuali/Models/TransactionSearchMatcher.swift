import Foundation

/// Matches transactions against the free-text query from the transactions
/// search field. Text queries match payee, category, and notes; queries that
/// parse as a currency amount also match the transaction amount, ignoring
/// sign so "12.50" finds both payments and refunds.
///
/// Digits the query leaves unspecified are treated as wildcards, so results
/// narrow progressively while typing toward an exact amount: "19" matches
/// 19.00-19.99, "19." the same, "19.0" matches 19.00-19.09, and "19.05" is
/// exact.
struct TransactionSearchMatcher {
    private let query: String
    /// Absolute amounts (in cents) the query matches, when it parses as one.
    private let amountRange: ClosedRange<Int>?

    init(_ query: String) {
        self.query = query.trimmingCharacters(in: .whitespaces)
        amountRange = Self.parseAmountRange(self.query)
    }

    /// The trimmed query text, for callers that push matching into SQL.
    var text: String { query }

    /// Absolute cent range the query matches as an amount, if it parses as
    /// one, for callers that push matching into SQL.
    var amountCentsRange: ClosedRange<Int>? { amountRange }

    func matches(_ transaction: Transaction) -> Bool {
        if query.isEmpty {
            return true
        }
        if transaction.payeeName?.localizedCaseInsensitiveContains(query) == true ||
            transaction.categoryName?.localizedCaseInsensitiveContains(query) == true ||
            transaction.notes?.localizedCaseInsensitiveContains(query) == true {
            return true
        }
        if let amountRange, amountRange.contains(abs(transaction.amount)) {
            return true
        }
        return false
    }

    /// Parse the query as a currency amount, e.g. "12", "12.50", "$12.50",
    /// "-12,5". Returns the range of absolute cent values it matches, with
    /// untyped fraction digits acting as wildcards. A separator followed by
    /// more than 2 digits (e.g. the grouping in "1,234") is ambiguous, so
    /// the query is not treated as an amount.
    private static func parseAmountRange(_ text: String) -> ClosedRange<Int>? {
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
            guard fractionPart.count <= 2 else { return nil }
        } else {
            integerPart = text[...]
            fractionPart = ""
        }

        let digits = integerPart + fractionPart
        guard !digits.isEmpty, digits.count <= 12,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let base = Int(digits) else { return nil }

        // One cents "slot" per untyped fraction digit: "19" -> 1900...1999,
        // "19.0" -> 1900...1909, "19.05" -> exactly 1905.
        let slot = fractionPart.count == 0 ? 100 : (fractionPart.count == 1 ? 10 : 1)
        let lower = base * slot
        return lower...(lower + slot - 1)
    }
}
