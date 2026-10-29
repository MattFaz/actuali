import Testing
@testable import Actuali

struct BudgetTransferAmountTests {
    @Test func leavesToBudgetCoverAmountUncapped() {
        #expect(
            BudgetTransferAmount.suggestedCoverAmount(
                overspentAmount: 5_000,
                availableInSource: nil
            ) == 5_000
        )
    }

    @Test func capsCoverAmountAtAvailableCategoryBalance() {
        #expect(
            BudgetTransferAmount.suggestedCoverAmount(
                overspentAmount: 5_000,
                availableInSource: 1_200
            ) == 1_200
        )
    }

    @Test func neverSuggestsMoreThanTheOverspentAmount() {
        #expect(
            BudgetTransferAmount.suggestedCoverAmount(
                overspentAmount: 1_200,
                availableInSource: 5_000
            ) == 1_200
        )
    }

    @Test func returnsZeroWhenCategoryHasNoAvailableFunds() {
        #expect(
            BudgetTransferAmount.suggestedCoverAmount(
                overspentAmount: 5_000,
                availableInSource: 0
            ) == 0
        )
    }

    @Test func rejectsNegativeAvailableBalanceAsCoverFunds() {
        #expect(
            BudgetTransferAmount.suggestedCoverAmount(
                overspentAmount: 5_000,
                availableInSource: -500
            ) == 0
        )
    }
}
