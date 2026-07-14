import SwiftUI

/// Where a category-transactions push originated on the Budget tab (GH #56):
/// the category name shows all time, the "Spent" caption shows one month.
struct CategoryTransactionsDestination: Hashable {
    let categoryId: String
    let categoryName: String
    /// "yyyy-MM" to narrow to one month; nil means all time.
    let month: String?
}

/// Every transaction counting toward one category's spend, pushed from the
/// Budget tab (GH #56). The row set mirrors the budget month's spent query
/// (see BudgetDatabase.fetchCategoryTransactions), so a month-scoped list
/// sums to the "Spent" figure the user tapped.
struct CategoryTransactionsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let destination: CategoryTransactionsDestination

    @State private var transactions: [Transaction] = []
    @State private var searchText = ""
    @State private var loaded = false
    @State private var editingTransaction: Transaction?

    private var scopeTitle: String {
        destination.month.map { MonthPicker.title(for: $0) } ?? "All Time"
    }

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
                    "No Transactions",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Nothing in \(destination.categoryName) for \(scopeTitle.lowercased() == "all time" ? "any month" : scopeTitle)")
                )
            } else {
                List {
                    Section {
                        if !transactions.isEmpty && filteredTransactions.isEmpty {
                            Text("No matching transactions")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(filteredTransactions) { transaction in
                            Group {
                                // Split children only display at full
                                // opacity, without tap/swipe: the edit form
                                // has no split support, and deleting one leg
                                // would break the parent's amount.
                                if transaction.parentId == nil {
                                    Button {
                                        editingTransaction = transaction
                                    } label: {
                                        TransactionRow(transaction: transaction)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    TransactionRow(transaction: transaction)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
                    } header: {
                        HStack {
                            Text(scopeTitle)
                            Spacer()
                            // Sums the filtered rows so the total matches
                            // what's on screen while searching.
                            Text("Total \(budgetStore.formatCurrency(filteredTransactions.reduce(0) { $0 + $1.amount }))")
                        }
                    }
                }
            }
        }
        .navigationTitle(destination.categoryName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search transactions")
        .task { await reload() }
        .refreshable {
            await budgetStore.sync()
            await reload()
        }
        .sheet(item: $editingTransaction, onDismiss: {
            Task { await reload() }
        }) { transaction in
            AddTransactionView(editing: transaction)
                .environmentObject(budgetStore)
        }
    }

    private func reload() async {
        transactions = await budgetStore.fetchCategoryTransactions(
            categoryId: destination.categoryId,
            month: destination.month
        )
        loaded = true
    }
}

#Preview {
    NavigationStack {
        CategoryTransactionsView(
            destination: CategoryTransactionsDestination(
                categoryId: "cat-1",
                categoryName: "Food",
                month: nil
            )
        )
        .environmentObject(BudgetStore.previewInstance())
    }
}
