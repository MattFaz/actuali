import Foundation
import Testing
@testable import Actuali

/// Pure validation/routing of split entry in `BudgetStore.plan(for:)`:
/// a form with split lines resolves to `.split` with signed parent and
/// child amounts, and malformed splits are rejected before any write.
@MainActor
struct BudgetStoreSplitPlanTests {

    private func form(
        type: TransactionType = .expense,
        amount: String = "10.00",
        splits: [BudgetStore.SplitLineForm] = []
    ) -> BudgetStore.TransactionForm {
        BudgetStore.TransactionForm(
            accountId: "acct-1",
            type: type,
            amount: amount,
            payeeName: "Market",
            transferToAccountId: nil,
            categoryId: nil,
            notes: "",
            date: Date(),
            cleared: false,
            splits: splits
        )
    }

    private func line(_ categoryId: String?, _ amount: String, notes: String = "") -> BudgetStore.SplitLineForm {
        BudgetStore.SplitLineForm(categoryId: categoryId, amount: amount, notes: notes)
    }

    @Test func splitExpenseSignsParentAndLines() throws {
        let plan = try BudgetStore.plan(for: form(
            type: .expense, amount: "10.00",
            splits: [line("cat-a", "6.00"), line("cat-b", "4.00", notes: "half")]
        ))
        #expect(plan == .split(amountCents: -1000, lines: [
            .init(categoryId: "cat-a", amountCents: -600, notes: nil),
            .init(categoryId: "cat-b", amountCents: -400, notes: "half")
        ]))
    }

    @Test func splitIncomeStaysPositive() throws {
        let plan = try BudgetStore.plan(for: form(
            type: .income, amount: "10.00",
            splits: [line("cat-a", "6.00"), line("cat-b", "4.00")]
        ))
        #expect(plan == .split(amountCents: 1000, lines: [
            .init(categoryId: "cat-a", amountCents: 600, notes: nil),
            .init(categoryId: "cat-b", amountCents: 400, notes: nil)
        ]))
    }

    @Test func splitLinesMustSumToTotal() {
        #expect(throws: BudgetStoreError.splitAmountMismatch) {
            try BudgetStore.plan(for: form(
                amount: "10.00",
                splits: [line("cat-a", "6.00"), line("cat-b", "3.00")]
            ))
        }
    }

    @Test func splitNeedsAtLeastTwoLines() {
        #expect(throws: BudgetStoreError.splitNeedsTwoLines) {
            try BudgetStore.plan(for: form(
                amount: "10.00",
                splits: [line("cat-a", "10.00")]
            ))
        }
    }

    @Test func splitLineWithUnparseableAmountIsRejected() {
        #expect(throws: BudgetStoreError.invalidAmount) {
            try BudgetStore.plan(for: form(
                amount: "10.00",
                splits: [line("cat-a", "abc"), line("cat-b", "4.00")]
            ))
        }
    }

    @Test func splitLineWithNonPositiveAmountIsRejected() {
        #expect(throws: BudgetStoreError.invalidAmount) {
            try BudgetStore.plan(for: form(
                amount: "10.00",
                splits: [line("cat-a", "0"), line("cat-b", "10.00")]
            ))
        }
    }

    @Test func transferTakesPrecedenceOverSplits() throws {
        // The form hides split entry for transfers; if stale lines linger in
        // the form state, the transfer still wins.
        var f = form(type: .transfer, amount: "25.00",
                     splits: [line("cat-a", "20.00"), line("cat-b", "5.00")])
        f.transferToAccountId = "acct-2"
        let plan = try BudgetStore.plan(for: f)
        #expect(plan == .transfer(toAccountId: "acct-2", amountCents: 2500))
    }
}
