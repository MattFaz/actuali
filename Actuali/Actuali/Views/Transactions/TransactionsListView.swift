import SwiftUI

struct TransactionsListView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var pager: TransactionPager?
    @State private var searchText = ""
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
        let created = TransactionPager { offset, limit, search in
            await store.fetchTransactions(
                limit: limit, offset: offset, search: search,
                unclearedOnly: store.hideClearedTransactions
            )
        }
        pager = created
        return created
    }

    private func reload() async {
        await currentPager().loadFirstPage(search: searchQuery)
    }

    var body: some View {
        Group {
            if let pager, pager.transactions.isEmpty, !budgetStore.isLoading {
                if searchQuery != nil {
                    ContentUnavailableView.search(text: searchText)
                } else if budgetStore.hideClearedTransactions {
                    ContentUnavailableView(
                        "No Uncleared Transactions",
                        systemImage: "checkmark.circle",
                        description: Text("Everything is cleared. Turn off Hide Cleared Transactions to see the rest.")
                    )
                } else {
                    ContentUnavailableView(
                        "No Transactions",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Transactions will appear here once you load a budget")
                    )
                }
            } else if let pager {
                List {
                    ForEach(pager.transactions) { transaction in
                        Button {
                            editingTransaction = transaction
                        } label: {
                            TransactionRow(transaction: transaction, onToggleCleared: {
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
        .readableWidth()
        .navigationTitle("All Accounts")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search transactions")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Toggle("Hide Cleared Transactions", isOn: $budgetStore.hideClearedTransactions)
            }
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
        .sheet(item: $editingTransaction) { transaction in
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
    /// Tap action for the cleared-status dot. Nil leaves the dot inert
    /// (split-child rows, contexts without a reload path). Reconciled rows
    /// confirm before invoking, since the store unlocks them instead.
    var onToggleCleared: (() -> Void)? = nil

    @State private var confirmingUnlock = false

    var accountName: String {
        budgetStore.accounts.first { $0.id == transaction.accountId }?.name ?? "Unknown Account"
    }

    private var isInOffBudgetAccount: Bool {
        budgetStore.offBudgetAccountIds.contains(transaction.accountId)
    }

    private var isTransfer: Bool {
        transaction.transferId != nil || transaction.transferAcct != nil
    }

    /// Caption under the payee. Off-budget accounts aren't categorized at all
    /// ("Off budget", GH #123); split parents show their children's breakdown
    /// ("Food $6.00, Refund +$4.00" — outflows unsigned, inflows keep a "+"
    /// so a credit line inside a spend split stays distinguishable, GH #216);
    /// transfers that can't take a category show "Transfer" instead of
    /// nagging "Uncategorized" (GH #104).
    private var categoryLabel: String {
        if isInOffBudgetAccount {
            return "Off budget"
        }
        if let portions = transaction.splitPortions, !portions.isEmpty {
            return portions.map { portion in
                let name = portion.categoryName ?? "Uncategorized"
                return "\(name) \(budgetStore.displaySpentCaption(portion.amount))"
            }.joined(separator: ", ")
        }
        if transaction.categoryName == nil, isTransfer,
           !transaction.needsCategory(offBudgetAccountIds: budgetStore.offBudgetAccountIds) {
            return "Transfer"
        }
        return transaction.categoryName ?? (transaction.isParent ? "Split" : "Uncategorized")
    }

    var body: some View {
        HStack(spacing: 10) {
            if let onToggleCleared {
                Button {
                    if transaction.reconciled {
                        confirmingUnlock = true
                    } else {
                        onToggleCleared()
                    }
                } label: {
                    ClearedIndicator(cleared: transaction.cleared, reconciled: transaction.reconciled)
                        // Grow the tap target beyond the 14 pt glyph without
                        // changing the row's layout.
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Toggles cleared status")
                .confirmationDialog(
                    "This transaction is reconciled. Unlock it to make changes?",
                    isPresented: $confirmingUnlock,
                    titleVisibility: .visible
                ) {
                    Button("Unlock") { onToggleCleared() }
                }
            } else {
                // Same footprint as the tappable variant so mixed lists
                // (split children under parents) keep their columns aligned.
                ClearedIndicator(cleared: transaction.cleared, reconciled: transaction.reconciled)
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                // Split parents may resolve no payee (mixed child payees) —
                // label them "Split" like the desktop app, not "Unknown".
                // Off-budget rows say "No payee": they're commonly payee-less
                // (balance adjustments) and "Unknown" read as a bug (GH #123).
                Text(transaction.payeeName
                     ?? (transaction.isParent ? "Split"
                         : (isInOffBudgetAccount ? "No payee" : "Unknown")))
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
                Text(budgetStore.displayBalance(transaction.amount))
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
