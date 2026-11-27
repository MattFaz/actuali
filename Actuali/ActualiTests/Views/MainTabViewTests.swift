import Testing
@testable import Actuali

struct MainTabViewTests {
    @Test func everyTabIsInTheBarWhenNothingIsHidden() {
        for tab in StartTab.allCases {
            #expect(MainTabView.isInTabBar(tab, hidden: [], selectedTag: StartTab.accounts.tabTag))
        }
    }

    @Test func hiddenTabLeavesTheBar() {
        #expect(!MainTabView.isInTabBar(.reports, hidden: [.reports], selectedTag: StartTab.budget.tabTag))
        #expect(!MainTabView.isInTabBar(.addTransaction, hidden: [.addTransaction], selectedTag: StartTab.budget.tabTag))
    }

    /// A quick action, deep link or the More row can land on a hidden page.
    @Test func hiddenTabKeepsItsSlotWhileSelected() {
        #expect(MainTabView.isInTabBar(.reports, hidden: [.reports], selectedTag: StartTab.reports.tabTag))
        #expect(MainTabView.isInTabBar(.addTransaction, hidden: [.addTransaction], selectedTag: StartTab.addTransaction.tabTag))
    }

    @Test func hidingOneTabLeavesTheOtherInTheBar() {
        #expect(MainTabView.isInTabBar(.addTransaction, hidden: [.reports], selectedTag: StartTab.accounts.tabTag))
        #expect(!MainTabView.isInTabBar(.reports, hidden: [.reports], selectedTag: StartTab.addTransaction.tabTag))
    }
}
