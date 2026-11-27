import Foundation
import Testing
@testable import Actuali

struct ContentViewTests {
    @Test func tabForDeepLinkMapsKnownRoutes() {
        #expect(ContentView.tab(forDeepLink: URL(string: "actuali://add-transaction")!) == StartTab.addTransaction.tabTag)
        #expect(ContentView.tab(forDeepLink: URL(string: "actuali://budget")!) == StartTab.budget.tabTag)
        #expect(ContentView.tab(forDeepLink: URL(string: "actuali://accounts")!) == StartTab.accounts.tabTag)
    }

    @Test func tabForDeepLinkReturnsNilForUnknownRoute() {
        #expect(ContentView.tab(forDeepLink: URL(string: "actuali://unknown")!) == nil)
        #expect(ContentView.tab(forDeepLink: URL(string: "https://example.com")!) == nil)
    }
}
