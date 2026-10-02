import Foundation
import Testing
@testable import Actuali

/// "Hide Income Group" is a device-local Budget View preference: off by
/// default, and written to UserDefaults when toggled.
@MainActor
struct BudgetStoreHideIncomeGroupTests {
    @Test func settingDefaultsToOff() {
        let store = BudgetStore.previewInstance()
        #expect(!store.hideIncomeGroup)
    }

    @Test func togglingWritesTheStoredPreference() {
        defer { UserDefaults.standard.removeObject(forKey: "hideIncomeGroup") }
        let store = BudgetStore.previewInstance()

        store.hideIncomeGroup = true
        #expect(UserDefaults.standard.bool(forKey: "hideIncomeGroup"))

        store.hideIncomeGroup = false
        #expect(!UserDefaults.standard.bool(forKey: "hideIncomeGroup"))
    }
}
