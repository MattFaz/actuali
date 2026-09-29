import Testing
@testable import Actuali

/// Category visibility on a transfer follows Actual's rule: only between an
/// on-budget and an off-budget account, on the on-budget leg (GH #561).
struct AddTransactionTransferCategoryTests {
    private func takesCategory(from: Bool?, to: Bool?, editedLeg: Bool? = nil) -> Bool {
        AddTransactionView.transferTakesCategory(
            fromOffBudget: from, toOffBudget: to, editedLegOffBudget: editedLeg
        )
    }

    @Test func onBudgetToOnBudgetHidesCategory() {
        #expect(!takesCategory(from: false, to: false))
    }

    @Test func onToOffBudgetShowsCategoryInBothDirections() {
        #expect(takesCategory(from: false, to: true))
        #expect(takesCategory(from: true, to: false))
    }

    @Test func offBudgetToOffBudgetHidesCategory() {
        #expect(!takesCategory(from: true, to: true))
    }

    @Test func missingAccountHidesCategory() {
        #expect(!takesCategory(from: false, to: nil))
        #expect(!takesCategory(from: nil, to: true))
    }

    @Test func editShowsCategoryOnlyOnTheOnBudgetLeg() {
        // An edit writes the form's category to the opened row alone, so the
        // off-budget leg of an on/off pair offers none.
        #expect(takesCategory(from: false, to: true, editedLeg: false))
        #expect(!takesCategory(from: false, to: true, editedLeg: true))
        #expect(!takesCategory(from: false, to: false, editedLeg: false))
    }
}
