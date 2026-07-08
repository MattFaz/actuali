import SwiftUI

struct AccountDetailView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let account: Account

    @State private var transactions: [Transaction] = []
    @State private var searchText = ""
    @State private var showingAddTransaction = false
    @State private var editingTransaction: Transaction?

    var filteredTransactions: [Transaction] {
        if searchText.isEmpty {
            return transactions
        }
        return transactions.filter { transaction in
            transaction.payeeName?.localizedCaseInsensitiveContains(searchText) == true ||
            transaction.categoryName?.localizedCaseInsensitiveContains(searchText) == true ||
            transaction.notes?.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Current Balance")
                    Spacer()
                    Text(budgetStore.formatCurrency(account.balance))
                        .fontWeight(.semibold)
                }
            }

            Section("Recent Transactions") {
                if transactions.isEmpty {
                    Text("No transactions")
                        .foregroundStyle(.secondary)
                } else if filteredTransactions.isEmpty {
                    Text("No matching transactions")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredTransactions) { transaction in
                        Button {
                            editingTransaction = transaction
                        } label: {
                            TransactionRow(transaction: transaction, showAccount: false)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task {
                                    await budgetStore.deleteTransaction(transaction)
                                    transactions = await budgetStore.fetchTransactions(for: account.id)
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
        .navigationTitle(account.name)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search transactions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddTransaction = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddTransaction, onDismiss: {
            Task {
                transactions = await budgetStore.fetchTransactions(for: account.id)
            }
        }) {
            AddTransactionView(accountId: account.id)
                .environmentObject(budgetStore)
        }
        .sheet(item: $editingTransaction, onDismiss: {
            Task {
                transactions = await budgetStore.fetchTransactions(for: account.id)
            }
        }) { transaction in
            AddTransactionView(editing: transaction)
                .environmentObject(budgetStore)
        }
        .task {
            transactions = await budgetStore.fetchTransactions(for: account.id)
        }
        .refreshable {
            await budgetStore.sync()
            transactions = await budgetStore.fetchTransactions(for: account.id)
        }
    }
}

#Preview {
    NavigationStack {
        AccountDetailView(
            account: Account(
                id: "1",
                name: "Checking",
                type: .checking,
                offBudget: false,
                closed: false,
                sortOrder: 0,
                balance: 245073
            )
        )
        .environmentObject(BudgetStore.previewInstance())
    }
}
