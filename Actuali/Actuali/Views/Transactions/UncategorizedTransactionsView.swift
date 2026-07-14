import SwiftUI

/// Every transaction still needing a category, for triage (GH #26). Mirrors
/// the WebUI's "uncategorized" pseudo-account: on-budget accounts only, split
/// children included, transfers excluded unless the other side is off-budget.
/// Tapping a row opens a category picker; picking one saves immediately.
struct UncategorizedTransactionsView: View {
    @EnvironmentObject var budgetStore: BudgetStore

    @State private var transactions: [Transaction] = []
    @State private var searchText = ""
    @State private var loaded = false
    @State private var categorizing: Transaction?
    @State private var pickedCategoryId: String?
    @State private var editingTransaction: Transaction?

    private var filteredTransactions: [Transaction] {
        if searchText.isEmpty {
            return transactions
        }
        let matcher = TransactionSearchMatcher(searchText)
        return transactions.filter { matcher.matches($0) }
    }

    var body: some View {
        Group {
            if transactions.isEmpty && loaded {
                ContentUnavailableView(
                    "All Categorized",
                    systemImage: "checkmark.circle",
                    description: Text("Every transaction has a category")
                )
            } else {
                List {
                    if !transactions.isEmpty && filteredTransactions.isEmpty {
                        Text("No matching transactions")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filteredTransactions) { transaction in
                        Button {
                            pickedCategoryId = nil
                            categorizing = transaction
                        } label: {
                            TransactionRow(transaction: transaction)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // Split children only get the categorize tap: the
                            // edit form has no split support, and deleting one
                            // leg would break the parent's amount.
                            if transaction.parentId == nil {
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
                    }
                }
            }
        }
        .navigationTitle("Uncategorized")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search transactions")
        .task { await reload() }
        .refreshable {
            await budgetStore.sync()
            await reload()
        }
        .sheet(item: $categorizing) { transaction in
            NavigationStack {
                CategoryPickerView(selectedCategoryId: $pickedCategoryId) {
                    Task { await assignCategory(pickedCategoryId, to: transaction) }
                }
            }
        }
        .sheet(item: $editingTransaction, onDismiss: {
            Task { await reload() }
        }) { transaction in
            AddTransactionView(editing: transaction)
                .environmentObject(budgetStore)
        }
    }

    private func reload() async {
        transactions = await budgetStore.fetchUncategorizedTransactions()
        loaded = true
    }

    private func assignCategory(_ categoryId: String?, to transaction: Transaction) async {
        guard let categoryId else { return }
        var updated = transaction
        updated.categoryId = categoryId
        updated.categoryName = budgetStore.categoryGroups
            .flatMap(\.categories)
            .first { $0.id == categoryId }?
            .name
        do {
            try await budgetStore.updateTransaction(updated, original: transaction)
        } catch {
            budgetStore.error = "Failed to categorize transaction: \(error.localizedDescription)"
        }
        await reload()
    }
}

#Preview {
    NavigationStack {
        UncategorizedTransactionsView()
            .environmentObject(BudgetStore.previewInstance())
    }
}
