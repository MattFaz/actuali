import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    let widgets: [DashboardWidget]

    /// Report transactions fetched once per dashboard load and shared by all
    /// widgets (previously each widget fetched the full set independently).
    /// nil while the fetch is in flight.
    @State private var reportTransactions: [Transaction]?

    /// Unsupported widgets never render as cards; a single top banner notes
    /// that only a limited set of reports is available.
    private var hasUnsupportedWidgets: Bool {
        widgets.contains {
            if case .unsupported = $0 { return true }
            return false
        }
    }

    private var visibleWidgets: [DashboardWidget] {
        widgets.filter {
            if case .unsupported = $0 { return false }
            return true
        }
    }

    var body: some View {
        if widgets.isEmpty {
            ContentUnavailableView(
                "No widgets",
                systemImage: "chart.bar.xaxis",
                description: Text("Configure your dashboard in the Actual Budget webapp; it will sync here.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if hasUnsupportedWidgets {
                        UnsupportedTypesNotice()
                    }
                    ForEach(visibleWidgets, id: \.id) { widget in
                        widgetView(for: widget)
                    }
                }
                .padding()
            }
            .task { await loadTransactions() }
        }
    }

    private func loadTransactions() async {
        guard let database = budgetStore.databaseForLogger else {
            reportTransactions = []
            return
        }
        reportTransactions = (try? await database.fetchTransactionsForReports()) ?? []
    }

    /// Budget-level context conditions need (on/off-budget ops, account-name
    /// matching) that isn't derivable from the transaction rows themselves.
    private var conditionsContext: ConditionsFilter.Context {
        ConditionsFilter.Context(
            offBudgetAccountIds: Set(budgetStore.accounts.filter(\.offBudget).map(\.id)),
            accountNames: Dictionary(
                budgetStore.accounts.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    @ViewBuilder
    private func widgetView(for widget: DashboardWidget) -> some View {
        switch widget {
        case .summary(_, let meta):
            WidgetCard(transactions: reportTransactions, loadingHeight: 80) { transactions in
                SummaryEngine.compute(meta: meta, transactions: transactions, today: Date(), context: conditionsContext)
            } content: { data in
                SummaryWidgetView(displayName: widget.displayName, data: data)
            }
        case .netWorth(_, let meta):
            WidgetCard(transactions: reportTransactions, loadingHeight: 180) { transactions in
                NetWorthEngine.compute(meta: meta, transactions: transactions, today: Date(), context: conditionsContext)
            } content: { data in
                NetWorthWidgetView(displayName: widget.displayName, data: data)
            }
        case .cashFlow(_, let meta):
            WidgetCard(transactions: reportTransactions, loadingHeight: 200) { transactions in
                CashFlowEngine.compute(
                    meta: meta,
                    transactions: transactions,
                    offBudgetAccountIds: Set(budgetStore.accounts.filter(\.offBudget).map(\.id)),
                    today: Date(),
                    context: conditionsContext
                )
            } content: { data in
                CashFlowWidgetView(displayName: widget.displayName, data: data)
            }
        case .spending(_, let meta):
            WidgetCard(transactions: reportTransactions, loadingHeight: 120) { transactions in
                SpendingEngine.compute(meta: meta, transactions: spendingScope(transactions), today: Date(), context: conditionsContext)
            } content: { data in
                SpendingWidgetView(
                    displayName: widget.displayName,
                    data: data,
                    comparisonLabel: comparisonLabel(for: meta)
                )
            }
        case .markdown(_, let meta):
            MarkdownWidgetView(meta: meta)
        case .unsupported:
            // Filtered out of visibleWidgets; listed in the top notice instead.
            EmptyView()
        }
    }

    /// Match WebUI spending-spreadsheet.ts default exclusions: drop
    /// off-budget accounts and income categories before computing.
    private func spendingScope(_ transactions: [Transaction]) -> [Transaction] {
        let offBudget = Set(budgetStore.accounts.filter { $0.offBudget }.map(\.id))
        let income = Set(
            budgetStore.categoryGroups.flatMap(\.categories).filter(\.isIncome).map(\.id)
        )
        return transactions.filter { transaction in
            !offBudget.contains(transaction.accountId)
            && !(transaction.categoryId.map { income.contains($0) } ?? false)
        }
    }

    private func comparisonLabel(for meta: SpendingMeta?) -> String {
        switch meta?.mode {
        case .budget?: return "vs budget"
        case .singleMonth?: return "vs \(meta?.compareTo ?? "prior")"
        case .average?, .none: return "vs avg"
        }
    }
}

/// Shared chrome for report widgets: shows the standard loading card until
/// the dashboard-wide transaction fetch lands, then computes the widget's
/// data once per fetch and hands it to `content`.
private struct WidgetCard<Value, Content: View>: View {
    let transactions: [Transaction]?
    let loadingHeight: CGFloat
    let compute: ([Transaction]) -> Value
    @ViewBuilder let content: (Value) -> Content

    @State private var value: Value?

    var body: some View {
        Group {
            if let value {
                content(value)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: loadingHeight)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .task(id: transactions) {
            guard let transactions else { return }
            value = compute(transactions)
        }
    }
}

#Preview("With widgets") {
    DashboardView(widgets: [
        .summary(id: "1", meta: SummaryMeta(name: "Spent This Month",
                                            timeFrame: nil, conditions: nil,
                                            conditionsOp: nil, content: nil)),
        .netWorth(id: "2", meta: NetWorthMeta(name: "Net Worth",
                                              timeFrame: nil, conditions: nil,
                                              conditionsOp: nil,
                                              interval: .monthly, mode: nil)),
        .unsupported(id: "3", type: "sankey-card")
    ])
    .environmentObject(BudgetStore.previewInstance())
}

#Preview("Empty") {
    DashboardView(widgets: [])
        .environmentObject(BudgetStore.previewInstance())
}
