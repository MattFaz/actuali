import Foundation
import Testing
@testable import Actuali

/// The "Show Quick Add Button" setting must default on, write through to UserDefaults
/// under the key `init()` reads back, and come back after a relaunch.
@MainActor
@Suite(.serialized)
struct BudgetStoreQuickAddButtonPreferenceTests {
    private let key = "showsQuickAddButton"

    /// Restores whatever the test host had, so the suite leaves no residue.
    private func withCleanDefaults(_ body: () -> Void) {
        let original = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    @Test func defaultsOn() {
        withCleanDefaults {
            #expect(BudgetStore.previewInstance().showsQuickAddButton)
            #expect(BudgetStore.previewInstanceLoadingPersistedPreferencesForTesting().showsQuickAddButton)
        }
    }

    @Test func persistsBothStatesAndRestoresThem() {
        withCleanDefaults {
            let store = BudgetStore.previewInstance()
            store.showsQuickAddButton = false
            #expect(UserDefaults.standard.object(forKey: key) as? Bool == false)
            #expect(!BudgetStore.previewInstanceLoadingPersistedPreferencesForTesting().showsQuickAddButton)

            store.showsQuickAddButton = true
            #expect(UserDefaults.standard.object(forKey: key) as? Bool == true)
            #expect(BudgetStore.previewInstanceLoadingPersistedPreferencesForTesting().showsQuickAddButton)
        }
    }
}
