import SwiftUI

struct AccountDetailView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let account: Account

    @State private var pager: TransactionPager?
    @State private var searchText = ""
    @State private var showingAddTransaction = false
    @State private var showingReconcile = false
    @State private var editingTransaction: Transaction?

    private var searchQuery: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The pager is created on first use rather than in init because its
    /// fetch closure needs the environment store, which isn't available
    /// until body/task time.
    private func currentPager() -> TransactionPager {
        if let pager { return pager }
        let store = budgetStore
        let accountId = account.id
        let created = TransactionPager { offset, limit, search in
            await store.fetchTransactions(
                accountId: accountId, limit: limit, offset: offset, search: search
            )
        }
        pager = created
        return created
    }

    private func reload() async {
        await currentPager().loadFirstPage(search: searchQuery)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Current Balance")
                    Spacer()
                    Text(budgetStore.displayBalance(account.balance))
                        .fontWeight(.semibold)
                }
            }

            Section("Recent Transactions") {
                if let pager, pager.transactions.isEmpty {
                    Text(searchQuery == nil ? "No transactions" : "No matching transactions")
                        .foregroundStyle(.secondary)
                } else if let pager {
                    ForEach(pager.transactions) { transaction in
                        Button {
                            editingTransaction = transaction
                        } label: {
                            TransactionRow(transaction: transaction, showAccount: false, onToggleCleared: {
                                Task {
                                    await budgetStore.toggleCleared(transaction)
                                    await reload()
                                }
                            })
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task {
                                    await budgetStore.deleteTransaction(transaction)
                                    await reload()
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
                    if pager.hasMore {
                        // Sentinel row: appearing near the bottom of the list
                        // pulls in the next page.
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .task { await pager.loadNextPage() }
                    }
                }
            }
        }
        .navigationTitle(account.name)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search transactions")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingReconcile = true
                } label: {
                    Image(systemName: "checkmark.seal")
                }
                .accessibilityLabel("Reconcile")
                Button {
                    showingAddTransaction = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingReconcile, onDismiss: {
            Task {
                await reload()
            }
        }) {
            ReconcileView(account: account)
                .environmentObject(budgetStore)
        }
        .sheet(isPresented: $showingAddTransaction, onDismiss: {
            Task {
                await reload()
            }
        }) {
            AddTransactionView(accountId: account.id)
                .environmentObject(budgetStore)
        }
        .sheet(item: $editingTransaction, onDismiss: {
            Task {
                await reload()
            }
        }) { transaction in
            AddTransactionView(editing: transaction)
                .environmentObject(budgetStore)
        }
        .task(id: searchText) {
            // Debounce keystrokes; the initial (empty) load runs immediately.
            if searchQuery != nil {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            await reload()
        }
        .refreshable {
            await budgetStore.sync()
            await reload()
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
