import Foundation
import Testing
@testable import Actuali

/// Pins `Transaction.needsCategory(offBudgetAccountIds:)`, the shared rule
/// behind the sync notification's "Needs a category" marker and the list
/// rows' "Transfer" label (GH #123, #104). Mirrors the WebUI's uncategorized
/// filter: split parents, off-budget accounts and transfers don't take a
/// category — unless the transfer's other side is off-budget.
struct TransactionNeedsCategoryTests {

    private func makeTransaction(categoryId: String? = nil, isParent: Bool = false,
                                 transferId: String? = nil,
                                 transferAcct: String? = nil) -> Transaction {
        Transaction(id: "t1", accountId: "acct1", date: 20260707, amount: -1250,
                    payeeId: nil, payeeName: nil, categoryId: categoryId,
                    categoryName: nil, notes: nil, cleared: false, reconciled: false,
                    transferId: transferId, isParent: isParent, parentId: nil,
                    tombstone: false, sortOrder: nil, importedPayee: nil,
                    transferAcct: transferAcct)
    }

    @Test func uncategorizedOnBudgetTransactionNeedsOne() {
        #expect(makeTransaction().needsCategory(offBudgetAccountIds: []))
    }

    @Test func categorizedTransactionDoesNot() {
        #expect(!makeTransaction(categoryId: "food").needsCategory(offBudgetAccountIds: []))
    }

    @Test func splitParentDoesNot() {
        // Categories live on the children; the parent never carries one.
        #expect(!makeTransaction(isParent: true).needsCategory(offBudgetAccountIds: []))
    }

    @Test func offBudgetAccountTransactionDoesNot() {
        #expect(!makeTransaction().needsCategory(offBudgetAccountIds: ["acct1"]))
    }

    @Test func onBudgetTransferDoesNot() {
        let transfer = makeTransaction(transferId: "leg-2", transferAcct: "acct2")
        #expect(!transfer.needsCategory(offBudgetAccountIds: []))
    }

    @Test func transferToOffBudgetAccountDoes() {
        // Money leaving the budget still needs a category (Actual's rule).
        let transfer = makeTransaction(transferId: "leg-2", transferAcct: "acct2")
        #expect(transfer.needsCategory(offBudgetAccountIds: ["acct2"]))
    }

    @Test func transferWithoutPayeeInfoDoesNot() {
        // transferred_id alone marks the row a transfer even when the payee
        // row (and its transfer_acct) is unavailable.
        #expect(!makeTransaction(transferId: "leg-2").needsCategory(offBudgetAccountIds: []))
    }
}
