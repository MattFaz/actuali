import Foundation
import Testing
@testable import Actuali

struct AddTransactionWithReviewIntentTests {

    @Test func buildsPrefillWithParsedAmount() {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let prefill = AddTransactionWithReviewIntent.prefill(
            accountId: "acct-1",
            amount: "$4.50",
            payee: "Blue Bottle",
            notes: "  Team coffee  ",
            categoryId: "cat-7",
            date: date,
            isIncome: false,
            cleared: true
        )
        #expect(prefill.accountId == "acct-1")
        #expect(prefill.amountCents == 450)
        #expect(prefill.payee == "Blue Bottle")
        #expect(prefill.notes == "Team coffee")
        #expect(prefill.categoryId == "cat-7")
        #expect(prefill.date == date)
        #expect(prefill.isIncome == false)
        #expect(prefill.cleared == true)
    }

    @Test(arguments: ["", "   ", "abc", "0", "-3"])
    func unparsableAmountLeavesAmountUnset(amount: String) {
        let prefill = AddTransactionWithReviewIntent.prefill(
            accountId: nil,
            amount: amount,
            payee: "",
            notes: "",
            categoryId: nil,
            date: Date(timeIntervalSince1970: 1_750_000_000),
            isIncome: false,
            cleared: false
        )
        #expect(prefill.amountCents == nil)
    }
}
