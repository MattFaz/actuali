import Foundation
import Testing
@testable import Actuali

/// The Budget menu's group-totals switch defaults to on and writes through to
/// UserDefaults, like the other display settings.
///
/// The restore-on-launch half isn't covered here: `previewInstance()` is built
/// by an init that skips every UserDefaults read, and the real init does file
/// system work no unit test should trigger. Same gap as the other display
/// settings suites.
@MainActor
struct BudgetStoreGroupTotalsTests {

    @Test func groupTotalsShowByDefault() {
        #expect(BudgetStore.previewInstance().showGroupTotals)
    }

    @Test func togglePersistsToUserDefaults() {
        let store = BudgetStore.previewInstance()
        store.showGroupTotals = false
        #expect(UserDefaults.standard.object(forKey: "showGroupTotals") as? Bool == false)
        store.showGroupTotals = true
        #expect(UserDefaults.standard.object(forKey: "showGroupTotals") as? Bool == true)
    }
}
