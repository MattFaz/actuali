import SwiftUI

struct TransactionsListView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var searchText = ""
    @State private var editingTransaction: Transaction?

    var filteredTransactions: [Transaction] {
        if searchText.isEmpty {
            return budgetStore.transactions
        }
        return budgetStore.transactions.filter { transaction in
            transaction.payeeName?.localizedCaseInsensitiveContains(searchText) == true ||
            transaction.categoryName?.localizedCaseInsensitiveContains(searchText) == true ||
            transaction.notes?.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    var body: some View {
        Group {
            if budgetStore.transactions.isEmpty && !budgetStore.isLoading {
                ContentUnavailableView(
                    "No Transactions",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Transactions will appear here once you load a budget")
                )
            } else {
                List {
                    ForEach(filteredTransactions) { transaction in
                        Button {
                            editingTransaction = transaction
                        } label: {
                            TransactionRow(transaction: transaction)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task {
                                    await budgetStore.deleteTransaction(transaction)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                editingTransaction = transaction
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.yellow)
                        }
                    }
                }
            }
        }
        .navigationTitle("All Accounts")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search transactions")
        .refreshable {
            await budgetStore.sync()
        }
        .sheet(item: $editingTransaction, onDismiss: {
            Task {
                await budgetStore.refreshData()
            }
        }) { transaction in
            AddTransactionView(editing: transaction)
                .environmentObject(budgetStore)
        }
        .overlay {
            if budgetStore.isLoading {
                ProgressView()
            }
        }
    }
}

struct TransactionRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let transaction: Transaction
    var showAccount: Bool = true

    var accountName: String {
        budgetStore.accounts.first { $0.id == transaction.accountId }?.name ?? "Unknown Account"
    }

    var body: some View {
        HStack(spacing: 10) {
            ClearedIndicator(cleared: transaction.cleared, reconciled: transaction.reconciled)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.payeeName ?? "Unknown")
                    .font(.body)
                HStack(spacing: 4) {
                    Text(transaction.categoryName ?? "Uncategorized")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let notes = transaction.notes, !notes.isEmpty {
                        Text("・")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if showAccount {
                    Text(accountName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(budgetStore.formatCurrency(transaction.amount))
                    .foregroundColor(transaction.isOutflow ? .primary : .green)
                Text(transaction.dateFormatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ClearedIndicator: View {
    let cleared: Bool
    let reconciled: Bool

    var body: some View {
        Group {
            if reconciled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
            } else if cleared {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 14))
        .accessibilityLabel(reconciled ? "Reconciled" : (cleared ? "Cleared" : "Uncleared"))
    }
}

#Preview {
    NavigationStack {
        TransactionsListView()
    }
    .environmentObject(BudgetStore.previewInstance())
}
