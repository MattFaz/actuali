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
        // Tests share the host app's UserDefaults.standard — restore whatever
        // was there (same convention as BudgetStoreAccountMappingTests).
        let saved = UserDefaults.standard.string(forKey: UncategorizedTapAction.defaultsKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: UncategorizedTapAction.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: UncategorizedTapAction.defaultsKey)
            }
        }

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
    
    @Test func routingCoversDefaultEditorAndSplitChild() {
        func transaction(parentId: String?) -> Transaction {
            Transaction(id: "t1", accountId: "acct", date: 20260101, amount: -1000,
                        cleared: false, reconciled: false, isParent: false,
                        parentId: parentId, tombstone: false)
        }

        // Default: always the picker, split child or not.
        #expect(!UncategorizedTapAction.categoryPicker.opensEditor(for: transaction(parentId: nil)))
        #expect(!UncategorizedTapAction.categoryPicker.opensEditor(for: transaction(parentId: "p1")))
        // Editor setting: plain rows open the editor, split children don't.
        #expect(UncategorizedTapAction.transactionEditor.opensEditor(for: transaction(parentId: nil)))
        #expect(!UncategorizedTapAction.transactionEditor.opensEditor(for: transaction(parentId: "p1")))
    }
}
