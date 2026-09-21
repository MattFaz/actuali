import Foundation
import Testing
@testable import Actuali

struct SettingsViewTests {
    @Test @MainActor func sectionsAreSortedAndRulesAreConditional() {
        #expect(SettingsView.preferencesItems.map(\.title) == [
            "Budget View", "Display", "Privacy", "Transactions & Automation",
        ])
        #expect(SettingsView.manageItems(includeRules: false).map(\.title) == [
            "Bank Sync (SimpleFIN & Wallet)", "Bills & Calendar", "Scheduled Transactions",
        ])
        #expect(SettingsView.manageItems(includeRules: true).map(\.title) == [
            "Bank Sync (SimpleFIN & Wallet)", "Bills & Calendar", "Rules", "Scheduled Transactions",
        ])
        #expect(SettingsView.informationItems.map(\.title) == ["About", "Support"])
    }

    @Test func shortcutSectionListsSharedWalletShortcut() {
        let items = SettingsView.shortcutItems

        #expect(items.map(\.title) == ["Log Wallet Payments Automatically"])
        #expect(items.first?.url.absoluteString == "https://www.icloud.com/shortcuts/48afadc0957a44fa9eaee51ca76ab0d6")
    }

    @Test func titlesSortCaseInsensitively() {
        let titles = ["Banana", "apple"]

        #expect(titles.sorted(by: SettingsView.titlePrecedes) == ["apple", "Banana"])
    }
}
