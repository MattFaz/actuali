import Foundation
import Testing
@testable import Actuali

@Suite(.serialized)
@MainActor
struct BudgetStoreFallbackServerTests {
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
        store.setServerClientForTesting(ActualServerClient())
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
}
