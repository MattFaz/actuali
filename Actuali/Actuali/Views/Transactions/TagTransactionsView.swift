import SwiftUI

struct TagTransactionsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.locale) private var locale

    let tag: Tag

    @State private var transactions: [Transaction] = []
    @State private var searchText = ""
    @State private var loaded = false
    @State private var editingTransaction: Transaction?
    @State private var editingTag = false

    private var needle: String {
        "#\(tag.tag)"
    }

    private var filteredTransactions: [Transaction] {
        if searchText.isEmpty {
            return transactions
        }
        let matcher = TransactionSearchMatcher(searchText)
        return transactions.filter { matcher.matches($0) }
    }

    private var totalSpent: Int {
        transactions.reduce(0) { sum, tx in
            tx.amount < 0 ? sum + (-tx.amount) : sum
        }
    }

    private var netAmount: Int {
        transactions.reduce(0) { sum, tx in
            sum + tx.amount
        }
    }

    private var dateRangeText: String? {
        let dates = transactions.compactMap(\.date).compactMap { DayDate(yyyymmdd: $0) }
        guard let minDate = dates.min(), let maxDate = dates.max() else { return nil }
        if minDate == maxDate {
            return minDate.iso
        }
        return "\(minDate.iso) – \(maxDate.iso)"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(tag.swiftUIColor)
                                .frame(width: 10, height: 10)
                            Text(tag.displayName)
                                .font(.title3.weight(.bold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(tag.swiftUIColor.opacity(0.15), in: Capsule())

                        Spacer()

                        Button {
                            editingTag = true
                        } label: {
                            Image(systemName: "pencil.circle")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Edit Tag"))
                    }

                    if let desc = tag.description, !desc.isEmpty {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "Total Spent"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(budgetStore.displaySpentCaption(totalSpent))
                                .font(.headline.weight(.semibold))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "Net Amount"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(budgetStore.formatCurrency(netAmount))
                                .font(.headline.weight(.semibold))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "Transactions"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(transactions.count)")
                                .font(.headline.weight(.semibold))
                        }
                    }

                    if let dateRangeText {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.caption2)
                            Text(dateRangeText)
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(String(localized: "Transactions")) {
                if !loaded, transactions.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if filteredTransactions.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No Transactions"),
                        systemImage: "number",
                        description: Text(String(format: String(localized: "No transactions tagged with %@"), tag.displayName))
                    )
                } else {
                    ForEach(filteredTransactions) { transaction in
                        TransactionListRow(
                            transaction: transaction,
                            showDate: true,
                            isSelectionMode: .constant(false),
                            isSelected: false,
                            editing: $editingTransaction,
                            onToggleSelect: {}
                        )
                    }
                }
            }
        }
        .navigationTitle(tag.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: Text(String(localized: "Search tagged transactions")))
        .refreshable {
            await loadTransactions()
        }
        .task {
            await loadTransactions()
        }
        .sheet(item: $editingTransaction) { transaction in
            NavigationStack {
                AddTransactionView(editing: transaction)
            }
        }
        .sheet(isPresented: $editingTag) {
            EditTagSheet(tag: tag)
        }
        .onChange(of: budgetStore.dataVersion) { _, _ in
            Task { await loadTransactions() }
        }
    }

    private func loadTransactions() async {
        // Fetch all transactions and filter by TagFilter.notesContainTag
        let all = await budgetStore.fetchTransactions(limit: 5000, offset: 0, search: nil)
        transactions = all.filter { tx in
            guard let notes = tx.notes, !notes.isEmpty else { return false }
            return TagFilter.notesContainTag(notes, tag: needle, caseSensitive: false)
        }
        loaded = true
    }
}
