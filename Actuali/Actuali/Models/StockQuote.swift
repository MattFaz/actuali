import Foundation

/// Real-time quote information for an equity/stock symbol.
struct StockQuote: Identifiable, Equatable, Hashable, Sendable {
    var id: String {
        symbol
    }

    /// Canonical ticker symbol (e.g. "AAPL", "RELIANCE.NS").
    let symbol: String

    /// Regular market price in currency units (e.g. 224.50).
    let price: Double

    /// Day change in currency units (e.g. +3.25 or -1.10).
    let dayChange: Double?

    /// Day percentage change (e.g. +1.47 for +1.47%).
    let dayChangePercent: Double?

    /// Currency code (e.g. "USD", "INR", "EUR"). Used to guard against mixing currencies.
    let currency: String?

    /// Timestamp when this quote was fetched.
    let lastUpdated: Date

    /// True if the stock traded up today.
    var isPositive: Bool {
        (dayChange ?? 0) >= 0
    }
}

/// Search result item returned from ticker autocomplete search.
struct StockSearchResult: Identifiable, Equatable, Hashable, Sendable {
    var id: String {
        symbol
    }

    let symbol: String
    let name: String?
    let exchange: String?
}
