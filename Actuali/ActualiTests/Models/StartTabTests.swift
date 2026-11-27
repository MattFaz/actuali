import Testing
@testable import Actuali

struct StartTabTests {
    /// Tags are fixed by the persisted start page and by the tab
    /// selections in MainTabView and NotificationRouter. They do not
    /// follow the position of the tabs in the tab bar. 2 was the Add tab
    /// and stays unused.
    @Test func tabTagsAreStable() {
        #expect(StartTab.accounts.tabTag == 0)
        #expect(StartTab.budget.tabTag == 1)
        #expect(StartTab.reports.tabTag == 3)
    }

    /// Add used to be a tab, and therefore a Start Page choice. Someone who
    /// picked it has "addTransaction" stored and now opens on Accounts.
    @Test func removedAddTransactionStartPageOpensAccounts() {
        #expect(StartTab(rawValue: "addTransaction") == nil)
        #expect(StartTab.resolved(from: "addTransaction") == .accounts)
    }

    @Test func resolvesDefaultWhenUnset() {
        #expect(StartTab.resolved(from: nil) == .accounts)
    }

    @Test func resolvesDefaultForUnknownValue() {
        #expect(StartTab.resolved(from: "settings") == .accounts)
        #expect(StartTab.resolved(from: "") == .accounts)
    }

    @Test func resolvesPersistedRawValues() {
        for tab in StartTab.allCases {
            #expect(StartTab.resolved(from: tab.rawValue) == tab)
        }
    }
}
