import Testing
@testable import Actuali

struct StartTabTests {

    // Tags are fixed by the persisted start page and by the tab
    // selections in MainTabView and NotificationRouter. They do not
    // follow the position of the tabs in the tab bar.
    @Test func tabTagsAreStable() {
        #expect(StartTab.accounts.tabTag == 0)
        #expect(StartTab.budget.tabTag == 1)
        #expect(StartTab.addTransaction.tabTag == 2)
        #expect(StartTab.reports.tabTag == 3)
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
