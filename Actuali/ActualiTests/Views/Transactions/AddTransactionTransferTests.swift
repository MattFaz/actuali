import Foundation
import GRDB
import Testing
@testable import Actuali

struct AddTransactionTransferTests {
    @Test(arguments: [TransactionType.expense, .income])
    @MainActor
    func selectingAnAccountPreservesNewTransactionsDirection(type: TransactionType) async throws {
        let (database, path) = try await makeTestDatabase(TestSchema.core + ["""
        INSERT INTO accounts (id, name) VALUES ('checking', 'Checking'), ('savings', 'Savings');
        INSERT INTO payees (id, transfer_acct) VALUES ('payee-checking', 'checking'), ('payee-savings', 'savings');
        INSERT INTO payee_mapping (id, targetId) VALUES ('payee-checking', 'payee-checking'), ('payee-savings', 'payee-savings');
        """])
        defer { cleanup(path) }
        let store = try await makeTestStore(database: database)
        store.accounts = try await database.fetchAccounts()
        store.payees = [
            Payee(id: "payee-checking", name: "", transferAccountId: "checking", tombstone: false),
            Payee(id: "payee-savings", name: "", transferAccountId: "savings", tombstone: false),
        ]
        let selection = AddTransactionView.transferAccountSelection(
            accountId: "checking", otherAccountId: "savings", type: type, isEditing: false
        )
        let form = BudgetStore.TransactionForm(
            accountId: selection.accountId, type: .transfer, amount: "100.00", payeeName: "",
            transferToAccountId: selection.partnerAccountId, categoryId: nil,
            notes: "", date: .now, cleared: false
        )

        try await store.saveTransaction(form)

        let amounts = try await database.dbQueueForTesting.read { db in
            try Row.fetchAll(db, sql: "SELECT acct, amount FROM transactions")
                .reduce(into: [String: Int]()) { result, row in
                    result[row["acct"] as String] = row["amount"] as Int
                }
        }
        let checkingAmount = type == .income ? 10000 : -10000
        #expect(amounts == ["checking": checkingAmount, "savings": -checkingAmount])
    }

    @Test(arguments: [TransactionType.expense, .income])
    func selectingAnAccountKeepsAnEditedRowInItsOwnAccount(type: TransactionType) {
        let selection = AddTransactionView.transferAccountSelection(
            accountId: "checking", otherAccountId: "savings", type: type, isEditing: true
        )

        #expect(selection.accountId == "checking")
        #expect(selection.partnerAccountId == "savings")
    }

    @Test(arguments: [
        (false, false, false, false, false, true), // New transaction.
        (false, false, false, true, true, true), // Convertible edit.
        (true, false, false, false, false, false), // Pending import.
        (false, true, false, false, false, false), // Split in progress.
        (false, false, true, true, false, false), // Split parent.
        (false, false, false, true, false, false), // Non-convertible edit.
    ])
    func transferEligibility(
        isPendingImportReview: Bool,
        isSplitting: Bool,
        isEditingSplitParent: Bool,
        isEditing: Bool,
        canConvertToTransfer: Bool,
        expected: Bool
    ) {
        #expect(AddTransactionView.offersTransfer(
            isPendingImportReview: isPendingImportReview,
            isSplitting: isSplitting,
            isEditingSplitParent: isEditingSplitParent,
            isEditing: isEditing,
            canConvertToTransfer: canConvertToTransfer
        ) == expected)
    }
}
