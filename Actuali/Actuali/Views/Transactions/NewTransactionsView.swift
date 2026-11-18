import SwiftUI

/// Every transaction still marked new, across accounts, so what a sync
/// brought in can be gone through in one place. Leaving clears the marks, as
/// an account's own screen does for its rows.
struct NewTransactionsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    @State private var transactions: [Transaction] = []
    @State private var loaded = false
    @State private var editingTransaction: Transaction?

    var body: some View {
        Group {
            if transactions.isEmpty, loaded {
                ContentUnavailableView(
                    String(localized: "No New Transactions"),
                    systemImage: "checkmark.circle"
                )
            } else {
                List(transactions) { transaction in
                    TransactionListRow(
                        transaction: transaction,
                        // No bulk actions here, so a long press selects nothing.
                        isSelectionMode: .constant(false),
                        editing: $editingTransaction
                    )
                }
            }
        }
        .readableWidth()
        .navigationTitle(String(localized: "New Transactions"))
        .navigationBarTitleDisplayMode(.inline)
        // An edit or delete bumps dataVersion, which is what re-reads the rows.
        .task(id: budgetStore.dataVersion) {
            transactions = await budgetStore.fetchUnreviewedTransactions()
            loaded = true
        }
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionView(editing: transaction)
                .environmentObject(budgetStore)
        }
        .onDisappear { budgetStore.markAllReviewed() }
    }
}
