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
            await store.fetchTransactions(limit: limit, offset: offset, search: search)
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
                if searchQuery == nil {
                    ContentUnavailableView(
                        "No Transactions",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Transactions will appear here once you load a budget")
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            } else if let pager {
                List {
                    ForEach(pager.transactions) { transaction in
                        Button {
                            editingTransaction = transaction
                        } label: {
                            TransactionRow(transaction: transaction, onToggleCleared: {
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
        .navigationTitle("All Accounts")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search transactions")
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
        .sheet(item: $editingTransaction, onDismiss: {
            Task {
                await budgetStore.refreshData()
                await reload()
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
    /// Tap action for the cleared-status dot. Nil leaves the dot inert
    /// (split-child rows, contexts without a reload path). Reconciled rows
    /// confirm before invoking, since the store unlocks them instead.
    var onToggleCleared: (() -> Void)? = nil

    @State private var confirmingUnlock = false

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
