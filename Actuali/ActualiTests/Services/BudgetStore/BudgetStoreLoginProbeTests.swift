import Foundation
import Testing
@testable import Actuali

/// Either fails the request outright or answers with a canned HTTP status, so
/// the login-methods probe can be driven down both paths without a server.
private final class ProbeTransport: URLProtocol {
    enum Outcome {
        case failure(URLError)
        case status(Int)
    }

    nonisolated(unsafe) static var outcome = Outcome.failure(URLError(.secureConnectionFailed))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.outcome {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .status(let code):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// `checkLoginMethods` deliberately swallows probe failures and falls back to
/// password login, which is right for older servers that lack the endpoint but
/// wrong when the server can't be reached at all — the user tapped Connect and
/// got no feedback whatsoever.
@Suite(.serialized)
@MainActor
struct BudgetStoreLoginProbeTests {

    private func makeStore(_ outcome: ProbeTransport.Outcome) async -> BudgetStore {
        ProbeTransport.outcome = outcome
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProbeTransport.self]
        let client = ActualServerClient(session: URLSession(configuration: config))
        try? await client.configure(serverURL: "https://budget.example.com")

        let store = BudgetStore.previewInstance()
        store.setServerClientForTesting(client)
        return store
    }

    @Test func unreachableServerTellsTheUserWhyInsteadOfFailingSilently() async {
        let store = await makeStore(.failure(URLError(.secureConnectionFailed)))

        await store.checkLoginMethods()

        let message = try? #require(store.error)
        #expect(message?.localizedCaseInsensitiveContains("certificate") == true)
    }

    /// Password login still has to be offered after a connection failure, so
    /// the user can fix the server and retry without restarting the app.
    @Test func passwordLoginRemainsAvailableAfterAConnectionFailure() async {
        let store = await makeStore(.failure(URLError(.cannotConnectToHost)))

        await store.checkLoginMethods()

        #expect(store.passwordLoginActive)
    }

    /// The silent fallback exists for servers predating the endpoint, or
    /// proxies stripping the route. A reachable server that simply can't
    /// answer the probe must not raise an alert.
    @Test func reachableServerWithAnUnusableProbeStillFallsBackQuietly() async {
        let store = await makeStore(.status(500))

        await store.checkLoginMethods()

        #expect(store.error == nil)
        #expect(store.passwordLoginActive)
    }
}
