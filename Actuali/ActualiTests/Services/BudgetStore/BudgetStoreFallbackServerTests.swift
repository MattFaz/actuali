import Foundation
import Testing
@testable import Actuali

private final class ConnectionEditTransport: URLProtocol {
    nonisolated(unsafe) static var unreachableHosts: Set<String> = []
    nonisolated(unsafe) static var requestedHosts: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.requestedHosts.append(host)
        if Self.unreachableHosts.contains(host) {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
@MainActor
struct BudgetStoreFallbackServerTests {
    private func makeClient(
        configuredFor serverURL: String,
        unreachableHosts: Set<String> = []
    ) async -> ActualServerClient {
        ConnectionEditTransport.unreachableHosts = unreachableHosts
        ConnectionEditTransport.requestedHosts = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionEditTransport.self]
        let client = ActualServerClient(session: URLSession(configuration: configuration))
        try? await client.configure(serverURL: serverURL)
        return client
    }

    @Test func connectNormalizesAndPersistsTheFallbackAddress() async {
        let store = BudgetStore.previewInstance()
        store.setServerClientForTesting(ActualServerClient())
        store.serverURL = "budget.example.com"
        store.fallbackServerURL = "  fallback.example.com  "

        await store.connect()

        #expect(store.fallbackServerURL == "https://fallback.example.com")
        #expect(
            UserDefaults.standard.string(forKey: "fallbackServerURL")
                == "https://fallback.example.com"
        )
    }

    @Test func connectSurfacesAMalformedFallbackInsteadOfFailingSilently() async {
        let store = BudgetStore.previewInstance()
        store.setServerClientForTesting(ActualServerClient())
        store.serverURL = "budget.example.com"
        store.fallbackServerURL = "https://"

        await store.connect()

        #expect(store.error == "Invalid fallback server URL")
    }

    @Test func connectedURLsCanBeReplacedWithoutDisconnectingOrRemovingTheBudget() async {
        let store = BudgetStore.previewInstance()
        store.setServerClientForTesting(await makeClient(configuredFor: "https://old.example.com"))
        store.serverURL = "https://old.example.com"
        store.isConnected = true
        store.currentBudgetId = "local-budget"

        let saved = await store.updateServerConnection(
            serverURL: " new.example.com/actual ",
            fallbackServerURL: " fallback.example.com "
        )

        #expect(saved)
        #expect(store.serverURL == "https://new.example.com/actual")
        #expect(store.fallbackServerURL == "https://fallback.example.com")
        #expect(store.isConnected)
        #expect(store.currentBudgetId == "local-budget")
    }

    @Test func invalidEditPreservesTheConnectedAddresses() async {
        let store = BudgetStore.previewInstance()
        store.setServerClientForTesting(ActualServerClient())
        store.serverURL = "https://primary.example.com"
        store.fallbackServerURL = "https://fallback.example.com"
        store.isConnected = true

        let saved = await store.updateServerConnection(
            serverURL: "https://replacement.example.com",
            fallbackServerURL: "https://"
        )

        #expect(!saved)
        #expect(store.serverURL == "https://primary.example.com")
        #expect(store.fallbackServerURL == "https://fallback.example.com")
        #expect(store.isConnected)
        #expect(store.error == "Invalid fallback server URL")
    }

    @Test func unreachableEditRestoresTheLiveClientAndSavedAddresses() async throws {
        let oldURL = "https://old.example.com"
        let client = await makeClient(
            configuredFor: oldURL,
            unreachableHosts: ["unreachable.example.com"]
        )
        let store = BudgetStore.previewInstance()
        store.setServerClientForTesting(client)
        store.serverURL = oldURL
        store.fallbackServerURL = "https://fallback.example.com"
        store.isConnected = true

        let saved = await store.updateServerConnection(
            serverURL: "https://unreachable.example.com",
            fallbackServerURL: ""
        )

        #expect(!saved)
        #expect(store.serverURL == oldURL)
        #expect(store.fallbackServerURL == "https://fallback.example.com")
        #expect(store.isConnected)

        ConnectionEditTransport.unreachableHosts = []
        _ = try await client.fetchLoginMethods()
        #expect(ConnectionEditTransport.requestedHosts.last == "old.example.com")
    }
}
