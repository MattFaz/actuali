import Testing
@testable import Actuali

struct AddTransactionSplitGateTests {
    @Test func plainTransactionOffersSplit() {
        #expect(AddTransactionView.canSplitIntoCategories(
            isTransfer: false, isEditingSplitParent: false, unsplitRequested: false
        ))
    }

    @Test func transferToggleHidesSplit() {
        // The live type toggle decides, not just a saved transfer: a new
        // transaction switched to Transfer can't be split (GH #556).
        #expect(!AddTransactionView.canSplitIntoCategories(
            isTransfer: true, isEditingSplitParent: false, unsplitRequested: false
        ))
    }

    @Test func splitParentOffersSplitOnlyAsUndo() {
        #expect(!AddTransactionView.canSplitIntoCategories(
            isTransfer: false, isEditingSplitParent: true, unsplitRequested: false
        ))
        #expect(AddTransactionView.canSplitIntoCategories(
            isTransfer: false, isEditingSplitParent: true, unsplitRequested: true
        ))
    }
}
