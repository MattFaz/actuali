import Foundation
import Testing
@testable import Actuali

private final class YahooMockTransport: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestedURLs: [URL] = []
    nonisolated(unsafe) static var requestedHeaders: [[String: String]] = []
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = ""

    static func reset(status: Int = 200, body: String = "") {
        requestedURLs = []
        requestedHeaders = []
        Self.status = status
        Self.body = body
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [YahooMockTransport.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestedURLs.append(request.url!)
        Self.requestedHeaders.append(request.allHTTPHeaderFields ?? [:])

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct YahooFinanceClientTests {
    private func makeClient(cacheTTL: TimeInterval = 300) -> YahooFinanceClient {
        YahooFinanceClient(session: YahooMockTransport.makeSession(), cacheTTL: cacheTTL)
    }

    @Test func fetchesAndParsesStockQuote() async throws {
        let json = """
        {
          "chart": {
            "result": [
              {
                "meta": {
                  "currency": "USD",
                  "symbol": "AAPL",
                  "regularMarketPrice": 225.50,
                  "chartPreviousClose": 220.00
                }
              }
            ],
            "error": null
          }
        }
        """
        YahooMockTransport.reset(body: json)
        let client = makeClient()

        let quote = await client.quote(for: "AAPL")
        let result = try #require(quote)

        #expect(result.symbol == "AAPL")
        #expect(result.price == 225.50)
        #expect(result.currency == "USD")
        #expect(result.dayChange == 5.50)
        #expect(result.dayChangePercent == 2.5) // (5.5 / 220) * 100
        #expect(result.isPositive == true)
        #expect(YahooMockTransport.requestedHeaders.first?["User-Agent"]?.contains("Mozilla") == true)
    }

    @Test func returnsCachedQuoteWithinTTL() async {
        let json = """
        {
          "chart": {
            "result": [
              {
                "meta": {
                  "currency": "USD",
                  "symbol": "AAPL",
                  "regularMarketPrice": 225.50,
                  "chartPreviousClose": 220.00
                }
              }
            ]
          }
        }
        """
        YahooMockTransport.reset(body: json)
        let client = makeClient(cacheTTL: 300)

        _ = await client.quote(for: "AAPL")
        #expect(YahooMockTransport.requestedURLs.count == 1)

        // Second request should hit cache
        let cached = await client.quote(for: "AAPL")
        #expect(cached?.price == 225.50)
        #expect(YahooMockTransport.requestedURLs.count == 1)

        // Force refresh should bypass cache
        _ = await client.quote(for: "AAPL", forceRefresh: true)
        #expect(YahooMockTransport.requestedURLs.count == 2)
    }

    @Test func searchesTickersAndReturnsResults() async {
        let json = """
        {
          "quotes": [
            {
              "symbol": "AAPL",
              "shortname": "Apple Inc.",
              "exchange": "NMS"
            },
            {
              "symbol": "AAPL.MX",
              "shortname": "APPLE INC",
              "exchange": "MEX"
            }
          ]
        }
        """
        YahooMockTransport.reset(body: json)
        let client = makeClient()

        let results = await client.search(query: "Apple")
        #expect(results.count == 2)
        #expect(results[0].symbol == "AAPL")
        #expect(results[0].name == "Apple Inc.")
        #expect(results[0].exchange == "NMS")
    }

    @Test func handlesNetworkErrorsGracefully() async {
        YahooMockTransport.reset(status: 500, body: "Server Error")
        let client = makeClient()

        let quote = await client.quote(for: "UNKNOWN")
        #expect(quote == nil)

        let search = await client.search(query: "BadQuery")
        #expect(search.isEmpty)
    }
}
