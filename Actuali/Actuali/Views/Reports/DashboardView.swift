import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    let widgets: [DashboardWidget]

    @State private var reportTransactions: [Transaction] = []
    @State private var customReportConfigs: [String: CustomReportConfig] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                widgetCards
            }
            .padding(.horizontal, 6)
            .padding(.vertical)
        }
        // Keyed to dataVersion so widgets recompute when transactions
        // change anywhere in the app (edits on other tabs, sync,
        // scheduled posts). ReportsTabView changes the view identity when
        // the widget set itself changes, so the task only needs dataVersion.
        .task(id: budgetStore.dataVersion) { await loadTransactions() }
    }

    @ViewBuilder
    private var widgetCards: some View {
        ForEach(widgets) { widget in
            switch widget {
            case .summary(let meta):
                SummaryWidgetView(meta: meta, transactions: reportTransactions)
            case .cashFlow(let meta):
                CashFlowWidgetView(meta: meta, transactions: reportTransactions)
            case .netWorth(let meta):
                NetWorthWidgetView(meta: meta, transactions: reportTransactions)
            case .spending(let meta):
                SpendingWidgetView(meta: meta, transactions: reportTransactions)
            case .balance(let meta):
                BalanceWidgetView(meta: meta, transactions: reportTransactions)
            case .customReport(_, let meta):
                CustomReportWidgetView(meta: meta, transactions: reportTransactions,
                                       config: customReportConfigs[meta?.id ?? ""])
            case .formula(let meta):
                FormulaWidgetView(displayName: meta?.name ?? "Formula", result: FormulaEngine.compute(
                    meta: meta,
                    transactions: reportTransactions,
                    today: Date(),
                    context: .empty
                ))
            }
        }
    }

    private func loadTransactions() async {
        guard let database = budgetStore.databaseForLogger else {
            reportTransactions = []
            return
        }
        // Fetch configs + week pref BEFORE assigning reportTransactions:
        // WidgetCard recomputes when the transactions change and the compute
        // closures read these, so they must land first.
        let reportIds = widgets.compactMap { widget -> String? in
            if case .customReport(_, let meta) = widget { return meta?.id }
            return nil
        }
        customReportConfigs = (try? await database.fetchCustomReportConfigs(ids: reportIds)) ?? [:]
        reportTransactions = (try? await database.fetchTransactionsForReports()) ?? []
    }
}
