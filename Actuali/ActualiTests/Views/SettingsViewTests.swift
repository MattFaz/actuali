import Testing
@testable import Actuali

struct SettingsViewTests {

    @Test @MainActor func sectionsAreSortedAndRulesAreConditional() {
        #expect(SettingsView.preferencesItems.map(\.title) == [
            "Budget View", "Display", "Privacy", "Transactions & Automation"
        ])
        #expect(SettingsView.manageItems(includeRules: false).map(\.title) == [
            "Bank Sync (SimpleFIN & Wallet)", "Bills & Calendar", "Scheduled Transactions"
        ])
        #expect(SettingsView.manageItems(includeRules: true).map(\.title) == [
            "Bank Sync (SimpleFIN & Wallet)", "Bills & Calendar", "Rules", "Scheduled Transactions"
        ])
    }

    @Test func titlesSortCaseInsensitively() {
        let titles = ["Banana", "apple"]

        #expect(titles.sorted(by: SettingsView.titlePrecedes) == ["apple", "Banana"])
    }
}
