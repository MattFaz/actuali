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

    private func line(_ categoryId: String?, _ amount: String, isOpposite: Bool = false, notes: String = "") -> BudgetStore.SplitLineForm {
        BudgetStore.SplitLineForm(categoryId: categoryId, amount: amount, isOpposite: isOpposite, notes: notes)
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
        // Direction is the line's flip, never a sign typed into the amount.
        for bad in ["0", "-10.00"] {
            #expect(throws: BudgetStoreError.invalidAmount) {
                try BudgetStore.plan(for: form(
                    amount: "10.00",
                    splits: [line("cat-a", bad), line("cat-b", "10.00")]
                ))
            }
        }
    }

    @Test func splitAllowsOppositeDirectionLines() throws {
        // A refund/credit line alongside spend lines (GH #216): the flipped
        // line runs against the expense sign into a positive child.
        let plan = try BudgetStore.plan(for: form(
            type: .expense, amount: "20.00",
            splits: [line("cat-a", "30.00"), line("cat-b", "10.00", isOpposite: true)]
        ))
        #expect(plan == .split(amountCents: -2000, lines: [
            .init(categoryId: "cat-a", amountCents: -3000, notes: nil),
            .init(categoryId: "cat-b", amountCents: 1000, notes: nil)
        ]))
    }

    @Test func oppositeDirectionLinesMustStillSumToTotal() {
        #expect(throws: BudgetStoreError.splitAmountMismatch) {
            try BudgetStore.plan(for: form(
                amount: "20.00",
                splits: [line("cat-a", "30.00"), line("cat-b", "5.00", isOpposite: true)]
            ))
        }
    }

    @Test func splitLineCarriesPayeeOverrideAndTrimsEmptyToInherit() throws {
        var overridden = line("cat-a", "6.00")
        overridden.payeeName = "Pharmacy"
        var inherited = line("cat-b", "4.00")
        inherited.payeeName = "   "

        let plan = try BudgetStore.plan(for: form(
            type: .expense, amount: "10.00",
            splits: [overridden, inherited]
        ))
        #expect(plan == .split(amountCents: -1000, lines: [
            .init(categoryId: "cat-a", amountCents: -600, notes: nil, payeeName: "Pharmacy"),
            .init(categoryId: "cat-b", amountCents: -400, notes: nil, payeeName: nil)
        ]))
    }

    @Test func splitLineCarriesChildIdForEditReconciliation() throws {
        var existing = line("cat-a", "6.00")
        existing.childId = "child-1"
        let plan = try BudgetStore.plan(for: form(
            type: .expense, amount: "10.00",
            splits: [existing, line("cat-b", "4.00")]
        ))
        #expect(plan == .split(amountCents: -1000, lines: [
            .init(categoryId: "cat-a", amountCents: -600, notes: nil, childId: "child-1"),
            .init(categoryId: "cat-b", amountCents: -400, notes: nil, childId: nil)
        ]))
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
