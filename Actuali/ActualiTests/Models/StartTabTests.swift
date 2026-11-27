import Testing
@testable import Actuali

struct StartTabTests {
    /// Tags are fixed by the persisted start page and by the tab
    /// selections in MainTabView and NotificationRouter. They do not
    /// follow the position of the tabs in the tab bar.
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

    @Test func onlyAddAndReportsAreHideable() {
        #expect(StartTab.allCases.filter(\.isHideable) == [.addTransaction, .reports])
    }

    @Test func hiddenTabsResolveFromPersistedRawValues() {
        #expect(StartTab.hidden(from: nil).isEmpty)
        #expect(StartTab.hidden(from: []).isEmpty)
        #expect(StartTab.hidden(from: ["reports", "addTransaction"]) == [.reports, .addTransaction])
    }

    /// A stale or edited default must never take Budget, Accounts or More out of the bar.
    @Test func hiddenTabsDropUnknownAndNonHideableValues() {
        #expect(StartTab.hidden(from: ["budget", "accounts", "settings", ""]).isEmpty)
        #expect(StartTab.hidden(from: ["budget", "reports", "more"]) == [.reports])
    }

    @Test func startPageFallsBackToAccountsWhenHidden() {
        #expect(StartTab.effective(start: .reports, hidden: [.reports]) == .accounts)
        #expect(StartTab.effective(start: .addTransaction, hidden: [.addTransaction, .reports]) == .accounts)
    }

    @Test func startPageIsKeptWhenNotHidden() {
        #expect(StartTab.effective(start: .reports, hidden: []) == .reports)
        #expect(StartTab.effective(start: .reports, hidden: [.addTransaction]) == .reports)
        #expect(StartTab.effective(start: .budget, hidden: [.addTransaction, .reports]) == .budget)
    }

    @Test func startPagePickerOmitsHiddenTabs() {
        #expect(StartTab.startPageOptions(hidden: []) == StartTab.allCases)
        #expect(StartTab.startPageOptions(hidden: [.reports]) == [.accounts, .budget, .addTransaction])
        #expect(StartTab.startPageOptions(hidden: [.addTransaction, .reports]) == [.accounts, .budget])
    }
}
