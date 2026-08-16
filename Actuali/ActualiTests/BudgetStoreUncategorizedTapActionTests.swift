import Foundation
import Testing
@testable import Actuali

/// The Uncategorized list's tap target (GH #260) defaults to the category
/// picker and writes through to UserDefaults, like the other display settings.
///
/// The restore-on-launch half isn't covered here: `previewInstance()` is built
/// by an init that skips every UserDefaults read, and the real init does file
/// system work no unit test should trigger. `resolved(from:)` stands in for it.
@MainActor
struct BudgetStoreUncategorizedTapActionTests {

    @Test func tapOpensCategoryPickerByDefault() {
        #expect(BudgetStore.previewInstance().uncategorizedTapAction == .categoryPicker)
    }

    @Test func changePersistsToUserDefaults() {
        let store = BudgetStore.previewInstance()
        store.uncategorizedTapAction = .transactionEditor
        #expect(UserDefaults.standard.string(forKey: UncategorizedTapAction.defaultsKey)
            == UncategorizedTapAction.transactionEditor.rawValue)
        store.uncategorizedTapAction = .categoryPicker
        #expect(UserDefaults.standard.string(forKey: UncategorizedTapAction.defaultsKey)
            == UncategorizedTapAction.categoryPicker.rawValue)
    }

    @Test func unsetOrUnknownValuesFallBackToCategoryPicker() {
        #expect(UncategorizedTapAction.resolved(from: nil) == .categoryPicker)
        #expect(UncategorizedTapAction.resolved(from: "somethingElse") == .categoryPicker)
        #expect(UncategorizedTapAction.resolved(from: "transactionEditor") == .transactionEditor)
    }
}
