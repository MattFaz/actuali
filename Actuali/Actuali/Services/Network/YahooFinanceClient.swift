import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "YahooFinance")

/// Actor responsible for querying public Yahoo Finance chart and search APIs.
/// Provides real-time quote feeds, search autocomplete, and memory caching.
actor YahooFinanceClient {
    private let session: URLSession
    private let cacheTTL: TimeInterval

    /// In-memory cache mapping `symbol -> (quote, fetchedAt)`.
    private var cache: [String: (quote: StockQuote, fetchedAt: Date)] = [:]

    init(session: URLSession = .shared, cacheTTL: TimeInterval = 300) {
        self.session = session
        self.cacheTTL = cacheTTL
    }

    /// Default browser-like User-Agent required by Yahoo Finance endpoints.
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    // MARK: - Quotes API

    /// Fetches a single quote for a symbol. Returns cached value if fetched within TTL, unless `forceRefresh` is true.
    func quote(for symbol: String, forceRefresh: Bool = false) async -> StockQuote? {
        let cleanSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanSymbol.isEmpty else { return nil }

        if !forceRefresh, let cached = cache[cleanSymbol], Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return cached.quote
        }

        guard let encoded = cleanSymbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1d") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return cache[cleanSymbol]?.quote
            }

            guard let quote = Self.parseChartResponse(data, symbol: cleanSymbol) else {
                return cache[cleanSymbol]?.quote
            }

            cache[cleanSymbol] = (quote, Date())
            return quote
        } catch {
            logger.notice("Quote fetch failed for \(cleanSymbol, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return cache[cleanSymbol]?.quote
        }
    }

    /// Fetches quotes for multiple symbols concurrently.
    func quotes(for symbols: [String], forceRefresh: Bool = false) async -> [String: StockQuote] {
        let uniqueSymbols = Array(Set(symbols.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() })).filter { !$0.isEmpty }
        guard !uniqueSymbols.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, StockQuote?).self) { group in
            for sym in uniqueSymbols {
                group.addTask {
                    let q = await self.quote(for: sym, forceRefresh: forceRefresh)
                    return (sym, q)
                }
            }

            var results: [String: StockQuote] = [:]
            for await (sym, q) in group {
                if let q {
                    results[sym] = q
                }
            }
            return results
        }
    }

    // MARK: - Search API

    /// Searches for ticker symbols and company names matching `query`.
    func search(query: String) async -> [StockSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/search?q=\(encoded)&quotesCount=10&newsCount=0") else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return Self.parseSearchResponse(data)
        } catch {
            return []
        }
    }

    // MARK: - Parsing Helpers

    private static func parseChartResponse(_ data: Data, symbol: String) -> StockQuote? {
        struct ChartEnvelope: Decodable {
            struct ChartBody: Decodable {
                struct ResultItem: Decodable {
                    struct Meta: Decodable {
                        let currency: String?
                        let symbol: String?
                        let regularMarketPrice: Double?
                        let chartPreviousClose: Double?
                        let previousClose: Double?
                    }

                    let meta: Meta
                }

                let result: [ResultItem]?
            }

            let chart: ChartBody
        }

        guard let envelope = try? JSONDecoder().decode(ChartEnvelope.self, from: data),
              let item = envelope.chart.result?.first else {
            return nil
        }

        let meta = item.meta
        guard let price = meta.regularMarketPrice, price > 0 else { return nil }

        let previousClose = meta.chartPreviousClose ?? meta.previousClose
        var dayChange: Double? = nil
        var dayChangePercent: Double? = nil

        if let previousClose, previousClose > 0 {
            let change = price - previousClose
            dayChange = change
            dayChangePercent = (change / previousClose) * 100.0
        }

        return StockQuote(
            symbol: meta.symbol ?? symbol,
            price: price,
            dayChange: dayChange,
            dayChangePercent: dayChangePercent,
            currency: meta.currency,
            lastUpdated: Date()
        )
    }

    private static func parseSearchResponse(_ data: Data) -> [StockSearchResult] {
        struct SearchEnvelope: Decodable {
            struct SearchQuote: Decodable {
                let symbol: String
                let shortname: String?
                let longname: String?
                let exchange: String?
                let quoteType: String?
            }

            let quotes: [SearchQuote]?
        }

        guard let envelope = try? JSONDecoder().decode(SearchEnvelope.self, from: data),
              let quotes = envelope.quotes else {
            return []
        }

        return quotes.compactMap { q in
            let sym = q.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !sym.isEmpty else { return nil }
            return StockSearchResult(
                symbol: sym,
                name: q.shortname ?? q.longname,
                exchange: q.exchange,
                quoteType: q.quoteType
            )
        }
    }
}
