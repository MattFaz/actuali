import Foundation
import Synchronization
import Testing
@testable import Actuali

/// Which hosts refuse connections, and which were asked. Mutable so a test
/// can bring a host back up mid-flight.
private final class HostLog: Sendable {
    let unreachable: Mutex<Set<String>>
    let requested = Mutex<[String]>([])

    init(unreachable: Set<String>) {
        self.unreachable = Mutex(unreachable)
    }
}

@Suite(.serialized)
@MainActor
struct BudgetStoreFallbackServerTests {
    private func makeClient(
        configuredFor serverURL: String,
        unreachableHosts: Set<String> = []
    ) async -> (ActualServerClient, HostLog) {
        let log = HostLog(unreachable: unreachableHosts)
        let session = StubTransport.session { request in
            let host = request.url?.host ?? ""
            log.requested.withLock { $0.append(host) }
            if log.unreachable.withLock({ $0.contains(host) }) {
                throw URLError(.cannotConnectToHost)
            }
            return StubTransport.Response(status: 404, contentType: "application/json")
        }
        let client = ActualServerClient(session: session)
        try? await client.configure(serverURL: serverURL)
        return (client, log)
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
        let (client, _) = await makeClient(configuredFor: "https://old.example.com")
        store.setServerClientForTesting(client)
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
        let (client, log) = await makeClient(
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
            fallbackServerURL: "https://replacement-fallback.example.com"
        )

        #expect(!saved)
        #expect(store.serverURL == oldURL)
        #expect(store.fallbackServerURL == "https://fallback.example.com")
        #expect(store.isConnected)

        log.unreachable.withLock { $0 = [] }
        _ = try await client.fetchLoginMethods()
        #expect(log.requested.withLock { $0.last } == "old.example.com")
    }
}
