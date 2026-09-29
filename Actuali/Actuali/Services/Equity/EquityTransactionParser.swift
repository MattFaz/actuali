import Foundation

/// Pure, non-isolated engine that resolves stock/equity positions from account transactions.
/// Operates on standard Actual Budget transactions without requiring custom schema or tables.
enum EquityTransactionParser {
    /// Result of parsing an individual trade transaction note.
    struct ParsedTrade: Equatable, Sendable {
        let shares: Double
        let price: Double?
    }

    /// Symbol and optional extracted company name.
    struct ExtractedSymbol: Equatable, Sendable {
        let symbol: String
        let name: String?
    }

    /// Precompiled regex for parsing tickers formatted as "Apple Inc. (AAPL)" or "AAPL".
    private static let parenthesizedSymbolRegex = try? NSRegularExpression(
        pattern: #"^(.*?)\s*\(([A-Za-z0-9\.\-\^]{1,12})\)$"#
    )

    /// Precompiled regex for plain symbols: 1-12 alphanumeric characters, dots, hyphens, or carets.
    private static let plainSymbolRegex = try? NSRegularExpression(
        pattern: #"^[A-Za-z0-9\.\-\^]{1,12}$"#
    )

    /// Trade note regex. Requires the unit word (shares/units) to prevent ordinary payees with
    /// a price note from generating phantom holdings. Handles:
    ///   "10 shares @ 150.00", "1.254 shares @ $220.50", "Buy 25 units @ ₹2900",
    ///   "Sold 5 shares @ 160", "50 shares" (no price).
    /// ponytail: requires "shares" or "units" as a guard; bare "10 @ price" no longer matches.
    private static let noteRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:(?:buy|sold?|sell)\s+)?([+-]?\d+(?:\.\d+)?)\s+(?:shares?|units?)\s*(?:@\s*[\$€£₹]?\s*(\d+(?:\.\d+)?))?"#
    )

    // MARK: - Symbol Extraction

    /// Extracts the canonical uppercase ticker symbol and optional name from a payee name.
    /// Returns `nil` if the payee does not represent a valid stock symbol.
    static func extractSymbol(from payeeName: String?) -> ExtractedSymbol? {
        guard let raw = payeeName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        // Exclude system words / reconciliations
        let lower = raw.lowercased()
        if lower.contains("reconciliation") || lower == "starting balance" || lower == "transfer" {
            return nil
        }

        let range = NSRange(location: 0, length: (raw as NSString).length)

        // Case 1: Name with parenthesized symbol: "Apple Inc. (AAPL)"
        if let regex = parenthesizedSymbolRegex,
           let match = regex.firstMatch(in: raw, options: [], range: range) {
            let nameRange = match.range(at: 1)
            let symbolRange = match.range(at: 2)
            let name = (raw as NSString).substring(with: nameRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let symbol = (raw as NSString).substring(with: symbolRange).uppercased()
            return ExtractedSymbol(symbol: symbol, name: name.isEmpty ? nil : name)
        }

        // Case 2: Plain symbol — must be all-uppercase (or contain . / - / ^) to avoid
        // ordinary mixed-case payee names ("T-Mobile" still has lowercase letters so it fails).
        if let regex = plainSymbolRegex,
           regex.firstMatch(in: raw, options: [], range: range) != nil {
            let trimmed = raw.uppercased()
            if raw == raw.uppercased() || raw.contains(".") || raw.contains("^") {
                return ExtractedSymbol(symbol: trimmed, name: nil)
            }
        }

        return nil
    }

    // MARK: - Note Parsing

    /// Parses trade quantity and optional execution price from a transaction's note.
    static func parseTradeDetails(from note: String?) -> ParsedTrade? {
        guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            return nil
        }

        let nsNote = note as NSString
        let range = NSRange(location: 0, length: nsNote.length)

        guard let regex = noteRegex,
              let match = regex.firstMatch(in: note, options: [], range: range) else {
            return nil
        }

        let qtyStr = nsNote.substring(with: match.range(at: 1))
        guard let qty = Double(qtyStr), qty != 0 else { return nil }

        var price: Double? = nil
        if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
            let priceStr = nsNote.substring(with: match.range(at: 2))
            price = Double(priceStr)
        }
        return ParsedTrade(shares: qty, price: price)
    }

    // MARK: - Holdings Aggregation

    /// Aggregates a list of transactions for an account into open equity holdings.
    /// Handles multiple buys, dollar-cost averaging (DCA), and partial sells.
    static func resolveHoldings(from transactions: [Transaction]) -> [EquityHolding] {
        struct PositionAccumulator {
            var symbol: String
            var name: String?
            var shares: Double = 0.0
            var totalInvestedCents: Int = 0
        }

        var accumulators: [String: PositionAccumulator] = [:]

        // Sort by date (ascending) so historical cost basis and sells apply in order
        let sortedTransactions = transactions
            .filter { !$0.tombstone && !$0.startingBalanceFlag }
            .sorted { ($0.date, $0.sortOrder ?? 0) < ($1.date, $1.sortOrder ?? 0) }

        for tx in sortedTransactions {
            guard let extracted = extractSymbol(from: tx.payeeName) else { continue }
            guard let trade = parseTradeDetails(from: tx.notes) else { continue }

            var acc = accumulators[extracted.symbol] ?? PositionAccumulator(
                symbol: extracted.symbol,
                name: extracted.name
            )
            if acc.name == nil, extracted.name != nil {
                acc.name = extracted.name
            }

            let isOutflow = tx.amount < 0
            let tradeShares = abs(trade.shares)

            if !isOutflow {
                // Buy: adds shares and cost basis.
                acc.shares += tradeShares
                acc.totalInvestedCents += abs(tx.amount)
            } else {
                // Sell: deducts shares and proportionally reduces cost basis.
                // The transaction amount is the cost basis of the shares sold (not proceeds).
                let sharesToDeduct = min(acc.shares, tradeShares)
                if acc.shares > 0 {
                    let costReduction = Int(round(Double(acc.totalInvestedCents) * (sharesToDeduct / acc.shares)))
                    acc.totalInvestedCents = max(0, acc.totalInvestedCents - costReduction)
                    acc.shares = max(0.0, acc.shares - sharesToDeduct)
                }
            }

            accumulators[extracted.symbol] = acc
        }

        // Return only positions that still hold shares, sorted alphabetically
        return accumulators.values
            .filter { $0.shares > 0.00001 }
            .map { acc in
                EquityHolding(
                    symbol: acc.symbol,
                    name: acc.name,
                    shares: acc.shares,
                    totalInvestedCents: acc.totalInvestedCents
                )
            }
            .sorted { $0.symbol < $1.symbol }
    }
}
