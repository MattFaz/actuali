import Foundation
import Testing
@testable import Actuali

/// The "Conventional Amount Entry" setting must survive app launches, so the
/// setter has to reach UserDefaults under the key `init()` reads back.
///
/// Only the write half is covered. `previewInstance()` goes through
/// `init(forPreview:)`, which reads no UserDefaults at all, so a "defaults to
/// off" assertion against it passes whatever the real `init()` does — the
/// read stays uncovered rather than faked.
@MainActor
struct BudgetStoreAmountEntryPreferenceTests {
    private let key = "conventionalAmountEntry"

    /// Restores whatever the test host had, so the suite leaves no residue.
    private func withCleanDefaults(_ body: () -> Void) {
        let original = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        body()
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test func conventionalAmountEntryPersistsBothStates() {
        withCleanDefaults {
            let store = BudgetStore.previewInstance()
            store.conventionalAmountEntry = true
            #expect(UserDefaults.standard.object(forKey: key) as? Bool == true)
            store.conventionalAmountEntry = false
            #expect(UserDefaults.standard.object(forKey: key) as? Bool == false)
        }
    }
}
