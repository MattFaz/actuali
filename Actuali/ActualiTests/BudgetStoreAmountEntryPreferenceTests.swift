import Foundation
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreAmountEntryPreferenceTests {
    private let key = "conventionalAmountEntry"

    @Test func conventionalAmountEntryDefaultsToOff() {
        UserDefaults.standard.removeObject(forKey: key)
        let store = BudgetStore.previewInstance()
        #expect(!store.conventionalAmountEntry)
    }

    @Test func conventionalAmountEntryPersistsWhenEnabled() {
        UserDefaults.standard.removeObject(forKey: key)
        let store = BudgetStore.previewInstance()
        store.conventionalAmountEntry = true
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == true)
        UserDefaults.standard.removeObject(forKey: key)
    }
}
