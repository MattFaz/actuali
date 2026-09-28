import Foundation

/// A stock/ETF holding within an equity or Demat investment account.
/// Derived by aggregating trade transactions for a specific ticker symbol.
struct EquityHolding: Identifiable, Equatable, Hashable, Sendable {
    /// Ticker symbol as uppercase identifier (e.g. "AAPL", "RELIANCE.NS").
    var id: String {
        symbol
    }

    /// Canonical ticker symbol.
    var symbol: String

    /// Optional company / asset name (e.g. "Apple Inc.").
    var name: String?

    /// Current net shares held. Supports fractional shares (e.g. 1.254).
    var shares: Double

    /// Total cost basis invested in cents.
    var totalInvestedCents: Int

    /// Weighted average purchase cost per share in cents.
    var averageCostCents: Int {
        guard shares > 0 else { return 0 }
        return Int(round(Double(totalInvestedCents) / shares))
    }

    /// Evaluates current market value in cents given the live stock price (in currency units/dollars).
    func marketValueCents(currentPrice: Double) -> Int {
        guard shares > 0, currentPrice > 0 else { return 0 }
        return Transaction.cents(fromDollars: shares * currentPrice) ?? 0
    }

    /// Unrealized profit or loss in cents (positive = gain, negative = loss).
    func unrealizedGainCents(currentPrice: Double) -> Int {
        marketValueCents(currentPrice: currentPrice) - totalInvestedCents
    }

    /// Return on investment percentage (e.g. 15.5 for +15.5%).
    func returnPercentage(currentPrice: Double) -> Double {
        guard totalInvestedCents > 0 else { return 0.0 }
        let gain = unrealizedGainCents(currentPrice: currentPrice)
        return (Double(gain) / Double(totalInvestedCents)) * 100.0
    }
}
