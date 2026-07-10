import SwiftUI

struct TransactionsListView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var searchText = ""
    @State private var editingTransaction: Transaction?

    var filteredTransactions: [Transaction] {
        if searchText.isEmpty {
            return budgetStore.transactions
        }
        let matcher = TransactionSearchMatcher(searchText)
        return budgetStore.transactions.filter { matcher.matches($0) }
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

    /// Caption under the payee. Split parents show their children's
    /// breakdown ("Food $6.00, Fun $4.00"); amounts are unsigned because the
    /// row's total already carries the sign.
    private var categoryLabel: String {
        if let portions = transaction.splitPortions, !portions.isEmpty {
            return portions.map { portion in
                let name = portion.categoryName ?? "Uncategorized"
                return "\(name) \(budgetStore.formatCurrency(abs(portion.amount)))"
            }.joined(separator: ", ")
        }
        return transaction.categoryName ?? (transaction.isParent ? "Split" : "Uncategorized")
    }

    var body: some View {
        HStack(spacing: 10) {
            ClearedIndicator(cleared: transaction.cleared, reconciled: transaction.reconciled)
            VStack(alignment: .leading, spacing: 2) {
                // Split parents may resolve no payee (mixed child payees) —
                // label them "Split" like the desktop app, not "Unknown".
                Text(transaction.payeeName ?? (transaction.isParent ? "Split" : "Unknown"))
                    .font(.body)
                HStack(spacing: 4) {
                    if transaction.isParent {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(categoryLabel)
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
