import Foundation
import Testing
@testable import Actuali

/// The "Category from Payee History" setting must survive app launches, so
/// the setter has to reach UserDefaults under the key `init()` reads back.
///
/// Only the write half is covered: `previewInstance()` reads no UserDefaults,
/// so a "defaults to on" assertion against it would pass whatever `init()` does.
@MainActor
struct BudgetStorePayeeHistoryPreferenceTests {
    private let key = "suggestCategoryFromPayeeHistory"

    @Test func payeeHistoryPreferencePersistsBothStates() {
        let original = UserDefaults.standard.object(forKey: key)
        defer { restoreUserDefault(key, to: original) }
        UserDefaults.standard.removeObject(forKey: key)

        let store = BudgetStore.previewInstance()
        store.suggestCategoryFromPayeeHistory = false
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == false)
        store.suggestCategoryFromPayeeHistory = true
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == true)
    }
}
