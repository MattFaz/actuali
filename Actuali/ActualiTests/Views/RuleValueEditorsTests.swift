import Testing
@testable import Actuali

/// The multi-picker's toggle logic. The picker only lists live, visible
/// entities, but a rule can reference hidden categories, closed accounts, or
/// ids authored on another client — toggling one item must never drop them.
struct RuleValueEditorsTests {

    private let visible = ["cat-a", "cat-b", "cat-c"]

    @MainActor @Test func togglingAddsAndRemovesAVisibleId() {
        let added = RuleIdMultiPicker.toggling("cat-b", in: .list([]), visibleIds: visible)
        #expect(added == .list([.string("cat-b")]))

        let removed = RuleIdMultiPicker.toggling("cat-b", in: added, visibleIds: visible)
        #expect(removed == .list([]))
    }

    @MainActor @Test func togglingKeepsVisibleIdsInChoiceOrder() {
        var value = RuleValue.list([])
        for id in ["cat-c", "cat-a"] {
            value = RuleIdMultiPicker.toggling(id, in: value, visibleIds: visible)
        }
        #expect(value == .list([.string("cat-a"), .string("cat-c")]))
    }

    @MainActor @Test func togglingPreservesIdsThePickerCannotDisplay() {
        let webAuthored = RuleValue.list([.string("hidden-cat"), .string("cat-a")])

        let toggled = RuleIdMultiPicker.toggling("cat-b", in: webAuthored, visibleIds: visible)
        #expect(toggled == .list([.string("cat-a"), .string("cat-b"), .string("hidden-cat")]))

        // A hidden id can still be removed explicitly.
        let removed = RuleIdMultiPicker.toggling("hidden-cat", in: toggled, visibleIds: visible)
        #expect(removed == .list([.string("cat-a"), .string("cat-b")]))
    }
}
