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

    /// Precompiled regexes for trade notes.
    /// Handles "10 shares @ 150.00", "10 @ $150", "qty: 10", "Sold 5 shares @ 200", etc.
    private static let noteQuantityAndPriceRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:buy\s+|sold\s+|sell\s+)?([+-]?\d+(?:\.\d+)?)\s*(?:shares?|units?|qty|@)\s*(?:@\s*[\$€£₹]?\s*(\d+(?:\.\d+)?))?"#
    )

    private static let noteExplicitQtyRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:qty|shares?|units?)\s*[:=]\s*([+-]?\d+(?:\.\d+)?)"#
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

        // Case 2: Plain symbol: "AAPL", "VOO", "RELIANCE.NS"
        if let regex = plainSymbolRegex,
           regex.firstMatch(in: raw, options: [], range: range) != nil {
            // Must have at least one uppercase letter or digit, not purely punctuation
            let trimmed = raw.uppercased()
            // Avoid matching common non-ticker single words if they are lowercase in user notes
            if raw == raw.uppercased() || raw.contains(".") || raw.contains("-") {
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

        // Try standard format: "10 shares @ 150.00" or "10 @ 150"
        if let regex = noteQuantityAndPriceRegex,
           let match = regex.firstMatch(in: note, options: [], range: range) {
            let qtyStr = nsNote.substring(with: match.range(at: 1))
            guard let qty = Double(qtyStr), qty != 0 else { return nil }

            var price: Double? = nil
            if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
                let priceStr = nsNote.substring(with: match.range(at: 2))
                price = Double(priceStr)
            }
            return ParsedTrade(shares: qty, price: price)
        }

        // Try key-value format: "qty: 10"
        if let regex = noteExplicitQtyRegex,
           let match = regex.firstMatch(in: note, options: [], range: range) {
            let qtyStr = nsNote.substring(with: match.range(at: 1))
            if let qty = Double(qtyStr), qty != 0 {
                return ParsedTrade(shares: qty, price: nil)
            }
        }

        return nil
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
                // Buy Trade (Inflow to asset account):
                // Adds shares and adds invested capital.
                acc.shares += tradeShares
                acc.totalInvestedCents += abs(tx.amount)
            } else {
                // Sell Trade (Outflow from asset account):
                // Deducts shares and proportionally reduces cost basis.
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
