import SwiftUI

struct AccountDetailView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let account: Account

    @State private var pager: TransactionPager?
    @State private var breakdown: AccountBalanceBreakdown?
    @State private var showingBreakdown = false
    @State private var searchText = ""
    @State private var showingAddTransaction = false
    @State private var showingReconcile = false
    @State private var showingWalletImport = false
    @State private var editingTransaction: Transaction?

    private var currentBalance: Int {
        budgetStore.accounts.first { $0.id == account.id }?.balance ?? account.balance
    }

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
                accountId: accountId, limit: limit, offset: offset, search: search,
                unclearedOnly: store.hideClearedTransactions
            )
        }
        pager = created
        return created
    }

    private func reload() async {
        breakdown = await budgetStore.balanceBreakdown(accountId: account.id)
        await currentPager().loadFirstPage(search: searchQuery)
    }

    private func breakdownRow(_ title: String, amount: Int) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(budgetStore.displayBalance(amount))
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    var body: some View {
        List {
            Section {
                // Tapping the balance reveals the cleared/uncleared/reconciled
                // split (GH #134), so the reconciled figure can be checked
                // against a bank statement without starting a reconciliation.
                Button {
                    withAnimation { showingBreakdown.toggle() }
                } label: {
                    HStack {
                        Text("Current Balance")
                        Spacer()
                        Text(budgetStore.displayBalance(currentBalance))
                            .fontWeight(.semibold)
                        if breakdown != nil {
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(showingBreakdown ? 180 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Current Balance, \(budgetStore.displayBalance(currentBalance))")
                .accessibilityHint(showingBreakdown ? "Hides the balance breakdown" : "Shows cleared, uncleared, and reconciled balances")

                if showingBreakdown, let breakdown {
                    breakdownRow("Cleared", amount: breakdown.cleared)
                    breakdownRow("Uncleared", amount: breakdown.uncleared)
                    breakdownRow("Reconciled", amount: breakdown.reconciled)
                }
            }

            Section("Recent Transactions") {
                if let pager, pager.transactions.isEmpty {
                    Text(searchQuery != nil
                        ? "No matching transactions"
                        : budgetStore.hideClearedTransactions
                            ? "No uncleared transactions"
                            : "No transactions")
                        .foregroundStyle(.secondary)
                } else if let pager {
                    ForEach(pager.transactions) { transaction in
                        Button {
                            editingTransaction = transaction
                        } label: {
                            TransactionRow(transaction: transaction, showAccount: false, onToggleCleared: {
                                Task { await budgetStore.toggleCleared(transaction) }
                            })
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await budgetStore.deleteTransaction(transaction) }
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
        .contentMargins(.horizontal, 6, for: .scrollContent)
        .navigationTitle(account.name)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search transactions")
        .toolbar {
            if WalletImportView.isSupported {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showingWalletImport = true
                    } label: {
                        Label("Import from Wallet", systemImage: "wallet.pass")
                    }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Toggle("Hide Cleared Transactions", isOn: $budgetStore.hideClearedTransactions)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingReconcile = true
                } label: {
                    Label("Reconcile", systemImage: "checkmark.seal")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddTransaction = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingReconcile) {
            ReconcileView(account: account)
                .environmentObject(budgetStore)
        }
        .sheet(isPresented: $showingWalletImport) {
            WalletImportView(preselectedAccountId: account.id)
                .environmentObject(budgetStore)
        }
        .sheet(isPresented: $showingAddTransaction) {
            AddTransactionView(accountId: account.id)
                .environmentObject(budgetStore)
        }
        .sheet(item: $editingTransaction) { transaction in
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
        .onChange(of: budgetStore.dataVersion) {
            // The store republished its data — refresh the cached page. This
            // is the single reload path for every mutation (row toggles,
            // deletes, sheet edits, sync, scheduled posts), so those sites
            // carry no reload calls of their own. Concurrent reloads are
            // safe: the pager's generation counter keeps the newest.
            Task { await reload() }
        }
        .onChange(of: budgetStore.hideClearedTransactions) {
            // The pager's fetch closure reads the flag, so a reload is all a
            // toggle flip needs.
            Task { await reload() }
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
