import Testing
@testable import Actuali

/// #283: shortcut paths (Log Transaction's retry prefill, the logger, and
/// Add Transaction with Review) all route a pinned category through
/// `existingCategoryId` so a category deleted since the shortcut was built
/// never reaches the form or the database as a dangling id.
@MainActor
struct BudgetStoreExistingCategoryIdTests {
    private func makeStore() -> BudgetStore {
        let store = BudgetStore.previewInstance()
        store.categoryGroups = [CategoryGroup(
            id: "grp-1", name: "Daily", isIncome: false, hidden: false, sortOrder: 0,
            categories: [Category(
                id: "cat-coffee", name: "Coffee", groupId: "grp-1",
                isIncome: false, hidden: false, sortOrder: 0
            )]
        )]
        return store
    }

    @Test func keepsACategoryThatExists() async {
        #expect(await makeStore().existingCategoryId("cat-coffee") == "cat-coffee")
    }

    @Test func dropsADeletedCategory() async {
        #expect(await makeStore().existingCategoryId("cat-deleted") == nil)
    }

    @Test func nilStaysNil() async {
        #expect(await makeStore().existingCategoryId(nil) == nil)
    }
}
