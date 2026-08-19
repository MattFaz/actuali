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
}
