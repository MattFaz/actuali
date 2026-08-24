import Foundation
import Testing
@testable import Actuali

struct SimpleFINAccessKeyTests {

    @Test func parsesTheProtocolsAccessKeyForm() throws {
        let key = try SimpleFINAccessKey.parse("https://user123:pass456@bridge.simplefin.org/simplefin")

        #expect(key.username == "user123")
        #expect(key.password == "pass456")
        #expect(key.baseURL.absoluteString == "https://bridge.simplefin.org/simplefin")
    }

    /// Bridge-generated passwords are arbitrary strings, so the split has to
    /// happen at the last "@" and the first ":", not the other way round.
    @Test func splitsAroundCredentialsContainingSeparators() throws {
        let key = try SimpleFINAccessKey.parse("https://user:p@ss:word@bridge.example.com/simplefin")

        #expect(key.username == "user")
        #expect(key.password == "p@ss:word")
        #expect(key.baseURL.absoluteString == "https://bridge.example.com/simplefin")
    }

    @Test func surroundingWhitespaceIsIgnored() throws {
        let key = try SimpleFINAccessKey.parse("  https://u:p@bridge.example.com/simplefin\n")

        #expect(key.username == "u")
        #expect(key.raw == "https://u:p@bridge.example.com/simplefin")
    }

    @Test(arguments: [
        "",
        "not-a-url",
        "https://bridge.example.com/simplefin",       // no credentials
        "https://user@bridge.example.com/simplefin",  // no password
        "https://:pass@bridge.example.com/simplefin", // no username
        // Cleartext is refused outright: the key travels in an Authorization
        // header and iOS would block the request anyway.
        "http://user:pass@bridge.example.com/simplefin"
    ])
    func rejectsKeysThatArentUsable(_ raw: String) {
        #expect(throws: SimpleFINError.invalidAccessKey) {
            _ = try SimpleFINAccessKey.parse(raw)
        }
    }

    @Test func basicAuthHeaderIsTheBase64OfUserAndPassword() throws {
        let key = try SimpleFINAccessKey.parse("https://demo:demo@bridge.example.com/simplefin")

        #expect(key.basicAuthHeader == "Basic \(Data("demo:demo".utf8).base64EncodedString())")
    }

    @Test func setupTokenDecodesToItsClaimURL() throws {
        let claim = "https://bridge.simplefin.org/simplefin/claim/abc123"
        let token = Data(claim.utf8).base64EncodedString()

        #expect(try SimpleFINAccessKey.claimURL(fromSetupToken: token).absoluteString == claim)
    }

    /// Tokens are pasted, so they arrive wrapped and padded in all sorts of ways.
    @Test func setupTokenSurvivesWrappingWhitespace() throws {
        let claim = "https://bridge.simplefin.org/simplefin/claim/abc123"
        let token = Data(claim.utf8).base64EncodedString()
        let wrapped = "\(token.prefix(8))\n\(token.dropFirst(8))  "

        #expect(try SimpleFINAccessKey.claimURL(fromSetupToken: wrapped).absoluteString == claim)
    }

    @Test(arguments: [
        "",
        "definitely not base64 ****",
        // Valid base64, but not a URL we'd ever POST to.
        "aGVsbG8gd29ybGQ=",                                     // "hello world"
        "aHR0cDovL2JyaWRnZS5leGFtcGxlLmNvbS9jbGFpbQ=="          // http:// claim URL
    ])
    func rejectsSetupTokensThatArentClaimURLs(_ token: String) {
        #expect(throws: SimpleFINError.invalidSetupToken) {
            _ = try SimpleFINAccessKey.claimURL(fromSetupToken: token)
        }
    }
}

struct SimpleFINAmountTests {

    @Test(arguments: [
        ("0", 0),
        ("12", 1200),
        ("-33.45", -3345),
        ("+33.45", 3345),
        ("1234.00", 123_400),
        // One decimal place is legal in the protocol and means tenths, not
        // hundredths — the trap a naive "drop the dot" parser falls into.
        ("12.3", 1230),
        ("-0.05", -5),
        // More than two places rounds, halves away from zero.
        ("1.005", 101),
        ("-1.005", -101),
        ("1.004", 100)
    ])
    func readsDecimalStringsAsCents(_ raw: String, _ expected: Int) {
        #expect(SimpleFINAmount.cents(from: raw) == expected)
    }

    @Test(arguments: ["", "abc", "12abc", "1.2.3", "1-2", "--1", "1 000.00", ".", "+"])
    func rejectsAnythingThatIsntADecimalString(_ raw: String) {
        #expect(SimpleFINAmount.cents(from: raw) == nil)
    }

    /// UTC, not the device's zone, so a transaction imported here lands on the
    /// same day as the same one imported by the web UI.
    @Test func datesAreTakenInUTC() {
        // 2024-03-01T00:30:00Z — the previous day anywhere west of Greenwich.
        #expect(SimpleFINAmount.day(fromTimestamp: 1_709_253_000) == 20240301)
        // 2019-06-03T16:40:53Z, the protocol documentation's own example time.
        #expect(SimpleFINAmount.day(fromTimestamp: 1_559_580_053) == 20190603)
    }

    @Test func startDatesConvertBackToMidnightUTC() {
        let timestamp = SimpleFINAmount.timestamp(fromDay: 20240301)

        #expect(timestamp == 1_709_251_200)
        #expect(SimpleFINAmount.day(fromTimestamp: timestamp) == 20240301)
    }
}

struct SimpleFINDecodingTests {

    /// The shape from the protocol documentation's example response.
    private let sample = """
    {
      "errors": ["Connection to Acme Bank may need attention"],
      "accounts": [
        {
          "org": {"domain": "mybank.com", "sfin-url": "https://sfin.mybank.com", "name": "My Bank"},
          "id": "2930002",
          "name": "Savings",
          "currency": "USD",
          "balance": "100.23",
          "available-balance": "75.23",
          "balance-date": 978366153,
          "transactions": [
            {
              "id": "12394832938",
              "posted": 978366153,
              "amount": "-33.45",
              "description": "Uncle Frank's Bait Shop",
              "payee": "Uncle Frank",
              "memo": "Worms",
              "transacted_at": 978360000
            },
            {
              "id": "12394832939",
              "posted": 0,
              "amount": "-12.00",
              "description": "Coffee",
              "pending": true,
              "transacted_at": 978370000
            }
          ]
        }
      ]
    }
    """

    private func decodeSample() throws -> SimpleFINAccountSet {
        try JSONDecoder().decode(SimpleFINAccountSet.self, from: Data(sample.utf8))
    }

    @Test func decodesAccountsAndTheirBalances() throws {
        let set = try decodeSample()

        #expect(set.errors == ["Connection to Acme Bank may need attention"])
        #expect(set.accounts.count == 1)
        let account = try #require(set.accounts.first)
        #expect(account.id == "2930002")
        #expect(account.name == "Savings")
        #expect(account.org.name == "My Bank")
        #expect(account.org.bankId == "mybank.com")
        #expect(account.balanceCents == 10023)
        #expect(account.availableBalance == "75.23")
        #expect(account.balanceDate == 978_366_153)
    }

    @Test func booksTransactionsByPostedAndPending() throws {
        let account = try #require(try decodeSample().accounts.first)
        let posted = try #require(account.transactions.first)
        let pending = try #require(account.transactions.last)

        #expect(posted.isBooked)
        #expect(posted.effectiveTimestamp == 978_366_153)
        #expect(posted.amountCents == -3345)
        #expect(posted.payee == "Uncle Frank")

        // Pending transactions have no posted date, so their date comes from
        // when they happened.
        #expect(!pending.isBooked)
        #expect(pending.effectiveTimestamp == 978_370_000)
    }

    /// A `balances-only` fetch omits `transactions` entirely.
    @Test func decodesAnAccountWithNoTransactionsKey() throws {
        let json = """
        {"accounts": [{"org": {"name": "My Bank"}, "id": "1", "name": "Checking", "balance": "5.00"}]}
        """
        let set = try JSONDecoder().decode(SimpleFINAccountSet.self, from: Data(json.utf8))

        #expect(set.errors.isEmpty)
        #expect(set.accounts.first?.transactions.isEmpty == true)
        #expect(set.accounts.first?.balanceCents == 500)
    }

    /// A bridge that sends something other than the protocol's array of
    /// strings must not cost us the accounts alongside it.
    @Test func survivesAnUnreadableErrorsField() throws {
        let json = """
        {"errors": [{"code": "NEEDS_ATTENTION"}],
         "accounts": [{"org": {"name": "My Bank"}, "id": "1", "name": "Checking", "balance": "5.00"}]}
        """
        let set = try JSONDecoder().decode(SimpleFINAccountSet.self, from: Data(json.utf8))

        #expect(set.errors.isEmpty)
        #expect(set.accounts.count == 1)
    }
}

// MARK: - Transport

private final class SimpleFINTransport: URLProtocol {
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
        configuration.protocolClasses = [SimpleFINTransport.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedURLs.append(request.url!)
        Self.requestedHeaders.append(request.allHTTPHeaderFields ?? [:])

        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct SimpleFINClientTests {
    private let accessKey = try! SimpleFINAccessKey.parse(
        "https://demo:demo@bridge.example.com/simplefin"
    )

    private func makeClient() -> SimpleFINClient {
        SimpleFINClient(session: SimpleFINTransport.makeSession())
    }

    @Test func claimingPostsToTheTokensURLAndReturnsTheKey() async throws {
        let claim = "https://bridge.example.com/simplefin/claim/abc"
        SimpleFINTransport.reset(body: "https://user:pass@bridge.example.com/simplefin")

        let key = try await makeClient().claimAccessKey(
            setupToken: Data(claim.utf8).base64EncodedString()
        )

        #expect(SimpleFINTransport.requestedURLs.map(\.absoluteString) == [claim])
        #expect(key.username == "user")
        #expect(key.password == "pass")
    }

    /// The bridge answers a re-used token with 200 and a "Forbidden" body, so
    /// the status code alone doesn't settle it.
    @Test func claimingRejectsAnAlreadyClaimedToken() async {
        SimpleFINTransport.reset(body: "Forbidden: token already claimed")
        let token = Data("https://bridge.example.com/claim/abc".utf8).base64EncodedString()

        await #expect(throws: SimpleFINError.claimRejected) {
            _ = try await makeClient().claimAccessKey(setupToken: token)
        }
    }

    @Test func claimingRejectsAForbiddenResponse() async {
        SimpleFINTransport.reset(status: 403, body: "")
        let token = Data("https://bridge.example.com/claim/abc".utf8).base64EncodedString()

        await #expect(throws: SimpleFINError.claimRejected) {
            _ = try await makeClient().claimAccessKey(setupToken: token)
        }
    }

    @Test func transactionFetchAsksForPendingAndTheNamedAccounts() async throws {
        SimpleFINTransport.reset(body: #"{"errors":[],"accounts":[]}"#)

        _ = try await makeClient().fetchAccounts(
            accessKey: accessKey, accountIds: ["a1", "a2"], startDate: 20240301
        )

        let url = try #require(SimpleFINTransport.requestedURLs.first)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        #expect(components.path == "/simplefin/accounts")
        #expect(items.contains(URLQueryItem(name: "start-date", value: "1709251200")))
        #expect(items.contains(URLQueryItem(name: "pending", value: "1")))
        #expect(items.filter { $0.name == "account" }.map(\.value) == ["a1", "a2"])
        #expect(!items.contains { $0.name == "balances-only" })
        #expect(
            SimpleFINTransport.requestedHeaders.first?["Authorization"] == accessKey.basicAuthHeader
        )
    }

    /// The account picker only needs balances, and asking for transactions
    /// makes the bridge do work nobody looks at.
    @Test func balanceOnlyFetchSkipsTransactions() async throws {
        SimpleFINTransport.reset(body: #"{"errors":[],"accounts":[]}"#)

        _ = try await makeClient().fetchAccounts(accessKey: accessKey)

        let url = try #require(SimpleFINTransport.requestedURLs.first)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items == [URLQueryItem(name: "balances-only", value: "1")])
    }

    @Test(arguments: [401, 403])
    func rejectedCredentialsSurfaceAsForbidden(_ status: Int) async {
        SimpleFINTransport.reset(status: status, body: "")

        await #expect(throws: SimpleFINError.forbidden) {
            _ = try await makeClient().fetchAccounts(accessKey: accessKey)
        }
    }

    @Test func unreadableBodySurfacesAsAnInvalidResponse() async {
        SimpleFINTransport.reset(body: "<html>not json</html>")

        await #expect(throws: SimpleFINError.invalidResponse) {
            _ = try await makeClient().fetchAccounts(accessKey: accessKey)
        }
    }
}
