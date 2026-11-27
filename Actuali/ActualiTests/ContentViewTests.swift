import Foundation
import Testing
@testable import Actuali

struct ContentViewTests {
    @Test func tabForDeepLinkMapsKnownRoutes() {
        #expect(ContentView.tab(forDeepLink: URL(string: "actuali://budget")!) == StartTab.budget.tabTag)
        #expect(ContentView.tab(forDeepLink: URL(string: "actuali://accounts")!) == StartTab.accounts.tabTag)
    }

    /// Add is a sheet now, not a tab, so its link has no tab to select.
    @Test func addTransactionDeepLinkOpensTheSheetInsteadOfATab() {
        let url = URL(string: "actuali://add-transaction")!
        #expect(ContentView.tab(forDeepLink: url) == nil)
        #expect(ContentView.opensAddTransaction(deepLink: url))
        #expect(!ContentView.opensAddTransaction(deepLink: URL(string: "actuali://budget")!))
        #expect(!ContentView.opensAddTransaction(deepLink: URL(string: "https://example.com")!))
    }

    @Test func tabForDeepLinkReturnsNilForUnknownRoute() {
        #expect(ContentView.tab(forDeepLink: URL(string: "actuali://unknown")!) == nil)
        #expect(ContentView.tab(forDeepLink: URL(string: "https://example.com")!) == nil)
    }
}
