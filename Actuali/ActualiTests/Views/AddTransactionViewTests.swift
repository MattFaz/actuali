import Testing
@testable import Actuali

struct AddTransactionViewTests {
    @Test func offBudgetAccountsHideStandardCategoryFields() {
        #expect(!AddTransactionView.showsStandardCategoryFields(accountIsOffBudget: true))
    }

    @Test func onBudgetAccountsShowStandardCategoryFields() {
        #expect(AddTransactionView.showsStandardCategoryFields(accountIsOffBudget: false))
    }
}
