import SwiftUI

struct CreditCardStatementDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var budgetStore: BudgetStore

    let account: Account
    let statement: CreditCardCycle.StatementRecord

    @State private var transactions: [Transaction] = []
    @State private var isLoading = true
    @State private var editingTransaction: Transaction?

    private var startStr: String {
        Transaction.formattedDate(from: statement.startDate.yyyymmdd, style: .abbreviated)
    }

    private var endStr: String {
        Transaction.formattedDate(from: statement.endDate.yyyymmdd, style: .abbreviated)
    }

    private var dueStr: String {
        Transaction.formattedDate(from: statement.dueDate.yyyymmdd, style: .abbreviated)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    detailRow(String(localized: "Statement Period"), value: "\(startStr) – \(endStr)")
                    detailRow(String(localized: "Statement Balance"), value: budgetStore.displayBalance(statement.statementBalance))
                    detailRow(String(localized: "Payment Due"), value: dueStr)
                    if statement.isPaid {
                        detailRow(String(localized: "Status"), value: String(localized: "Paid"), highlightGreen: true)
                    } else {
                        detailRow(String(localized: "Remaining Due"), value: budgetStore.displayBalance(statement.remainingDue))
                    }
                    detailRow(String(localized: "Cycle Spend"), value: budgetStore.displayBalance(statement.totalSpend))
                    if statement.paymentsSince > 0 {
                        detailRow(String(localized: "Payments & Credits"), value: budgetStore.displayBalance(statement.paymentsSince))
                    }
                }

                if transactions.isEmpty {
                    if isLoading {
                        Section {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        }
                    } else {
                        Section {
                            ContentUnavailableView {
                                Label(String(localized: "No transactions in this statement"), systemImage: "tray")
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                } else {
                    if budgetStore.transactionDisplayMode == .groupedByDate {
                        let groups = transactions.groupedByDate()
                        ForEach(groups) { group in
                            Section(group.title) {
                                ForEach(group.transactions) { tx in
                                    TransactionListRow(
                                        transaction: tx,
                                        showAccount: false,
                                        showDate: false,
                                        isSelectionMode: .constant(false),
                                        isSelected: false,
                                        editing: $editingTransaction
                                    )
                                }
                            }
                        }
                    } else {
                        Section(String(localized: "Transactions")) {
                            ForEach(transactions) { tx in
                                TransactionListRow(
                                    transaction: tx,
                                    showAccount: false,
                                    showDate: true,
                                    isSelectionMode: .constant(false),
                                    isSelected: false,
                                    editing: $editingTransaction
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Statement Details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Done")) {
                        dismiss()
                    }
                }
            }
            .sheet(item: $editingTransaction, onDismiss: {
                Task { await loadTransactions() }
            }) { transaction in
                AddTransactionView(editing: transaction)
                    .environmentObject(budgetStore)
            }
            .task {
                await loadTransactions()
            }
        }
    }

    private func detailRow(_ title: String, value: String, highlightGreen: Bool = false) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(highlightGreen ? .green : .primary)
        }
    }

    private func loadTransactions() async {
        isLoading = true
        transactions = await budgetStore.fetchStatementTransactions(
            accountId: account.id,
            startDate: statement.startDate.yyyymmdd,
            endDate: statement.endDate.yyyymmdd
        )
        isLoading = false
    }
}
