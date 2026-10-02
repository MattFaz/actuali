import SwiftUI

struct DashboardLoadRequest: Equatable {
    let databaseID: ObjectIdentifier?
    let dataVersion: Int
}

struct WidgetComputationRequest: Equatable {
    let transactions: [Transaction]?
    let localeIdentifier: String
    let dataVersion: Int
}

struct DashboardView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let widgets: [DashboardWidget]

    /// Report transactions fetched once per dashboard load and shared by all
    /// widgets (previously each widget fetched the full set independently).
    /// nil while the fetch is in flight.
    @State private var reportTransactions: [Transaction]?
    @State private var reportDataVersion = 0
    @State private var reportDate = Date()

    /// Configs referenced by custom-report widgets plus the week-start pref,
    /// loaded alongside the transactions.
    @State private var customReportConfigs: [String: CustomReportConfig] = [:]
    @State private var firstDayOfWeekIdx = 0

    /// Budget/schedule inputs some widgets need, fetched only when such a
    /// widget is on the dashboard (same pattern as customReportConfigs).
    @State private var reportBudgets = BudgetDatabase.ReportBudgetData()
    @State private var trackingBudgetMonths: [BalanceForecastBudgetMonth] = []
    @State private var forecastSchedules: [Schedule] = []

    /// Unsupported widgets never render as cards; a single top banner notes
    /// that only a limited set of reports is available.
    @State private var loadError: String?

    private var hasUnsupportedWidgets: Bool {
        widgets.contains {
            if case .unsupported = $0 {
                return true
            }
            return false
        }
    }

    private var visibleWidgets: [DashboardWidget] {
        widgets.filter {
            if case .unsupported = $0 {
                return false
            }
            return true
        }
    }

    private var widgetCards: some View {
        ForEach(visibleWidgets, id: \.id) { widget in
            widgetView(for: widget)
        }
    }

    var body: some View {
        if widgets.isEmpty {
            ContentUnavailableView(
                "No widgets",
                systemImage: "chart.bar.xaxis",
                description: Text("Configure your dashboard in the Actual Budget webapp; it will sync here.")
            )
        } else if let loadError {
            ContentUnavailableView(
                "Could not load reports",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else {
            ScrollView {
                // Regular width (iPad, never iPhone) tiles the cards two-up
                // rather than running one column down the middle. Adaptive
                // rather than a fixed pair, so a card never gets squeezed
                // below phone width in a narrow window or beside a sidebar —
                // below ~660 pt of content the grid falls back to one column.
                LazyVStack(spacing: 12) {
                    // Full width above the cards rather than taking a grid
                    // cell of its own — it describes the whole dashboard.
                    if hasUnsupportedWidgets {
                        UnsupportedTypesNotice()
                    }
                    if horizontalSizeClass == .regular {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 320), spacing: 12)],
                            spacing: 12
                        ) {
                            widgetCards
                        }
                    } else {
                        widgetCards
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical)
            }
            // Keyed to dataVersion so widgets recompute when transactions
            // change anywhere in the app (edits on other tabs, sync,
            // scheduled posts) — not just on first appearance.
            .task(id: currentLoadRequest) {
                await loadTransactions(request: currentLoadRequest)
            }
        }
    }

    private var currentLoadRequest: DashboardLoadRequest {
        DashboardLoadRequest(
            databaseID: budgetStore.databaseForLogger.map(ObjectIdentifier.init),
            dataVersion: budgetStore.dataVersion
        )
    }

    nonisolated static func shouldPublish(
        request: DashboardLoadRequest,
        currentRequest: DashboardLoadRequest,
        taskIsCancelled: Bool
    ) -> Bool {
        !taskIsCancelled && request == currentRequest
    }

    nonisolated static func errorMessageToPublish(
        error: any Error,
        request: DashboardLoadRequest,
        currentRequest: DashboardLoadRequest,
        taskIsCancelled: Bool
    ) -> String? {
        guard shouldPublish(
            request: request,
            currentRequest: currentRequest,
            taskIsCancelled: taskIsCancelled
        ) else { return nil }
        return error.localizedDescription
    }

    private func loadTransactions(request: DashboardLoadRequest) async {
        guard let database = budgetStore.databaseForLogger else {
            guard Self.shouldPublish(
                request: request,
                currentRequest: currentLoadRequest,
                taskIsCancelled: Task.isCancelled
            ) else { return }
            reportTransactions = []
            return
        }
        do {
            let today = Date()
            // Fetch configs + week pref BEFORE assigning reportTransactions:
            // WidgetCard recomputes when the transactions change and the compute
            // closures read these, so they must land first.
            let reportIds = widgets.compactMap { widget -> String? in
                if case .customReport(_, let meta) = widget {
                    return meta?.id
                }
                return nil
            }
            let loadedConfigs = try await database.fetchCustomReportConfigs(ids: reportIds)
            try Task.checkCancellation()

            let loadedFirstDayOfWeekIdx = try await database.fetchFirstDayOfWeekIdx()
            try Task.checkCancellation()

            let needsBudgets = widgets.contains {
                switch $0 {
                case .budgetAnalysis, .sankey, .balanceForecast: true
                case .spending(_, let meta): meta?.mode == .budget
                // Budgeted custom reports read budget cells instead of transactions.
                case .customReport(_, let meta):
                    (meta?.id).flatMap { loadedConfigs[$0] }?.balanceType == "Budgeted"
                default: false
                }
            }
            let loadedReportBudgets = needsBudgets
                ? try await database.fetchBudgetDataForReports()
                : BudgetDatabase.ReportBudgetData()
            try Task.checkCancellation()

            let needsForecast = widgets.contains {
                if case .balanceForecast = $0 {
                    return true
                }
                return false
            }
            let loadedForecastSchedules: [Schedule] = if needsForecast {
                try await database.fetchForecastSchedules()
            } else {
                []
            }
            try Task.checkCancellation()

            let loadedTrackingBudgetMonths: [BalanceForecastBudgetMonth] = if needsForecast {
                try await database.fetchTrackingBudgetMonths()
            } else {
                []
            }
            try Task.checkCancellation()

            let loadedTransactions = try await database.fetchTransactionsForReports()
            try Task.checkCancellation()

            guard Self.shouldPublish(
                request: request,
                currentRequest: currentLoadRequest,
                taskIsCancelled: Task.isCancelled
            ) else { return }
            customReportConfigs = loadedConfigs
            firstDayOfWeekIdx = loadedFirstDayOfWeekIdx
            reportBudgets = loadedReportBudgets
            forecastSchedules = loadedForecastSchedules
            trackingBudgetMonths = loadedTrackingBudgetMonths
            reportTransactions = loadedTransactions
            reportDate = today
            reportDataVersion += 1
            loadError = nil
        } catch {
            guard let errorMessage = Self.errorMessageToPublish(
                error: error,
                request: request,
                currentRequest: currentLoadRequest,
                taskIsCancelled: Task.isCancelled
            ) else { return }
            loadError = errorMessage
        }
    }

    /// Budget-level context conditions need (on/off-budget ops, account-name
    /// matching) that isn't derivable from the transaction rows themselves.
    private var conditionsContext: ConditionsFilter.Context {
        ConditionsFilter.Context(
            offBudgetAccountIds: Set(budgetStore.accounts.filter(\.offBudget).map(\.id)),
            accountNames: Dictionary(
                budgetStore.accounts.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            ),
            categoryGroupIds: Dictionary(
                budgetStore.categoryGroups.flatMap(\.categories).map { ($0.id, $0.groupId) },
                uniquingKeysWith: { first, _ in first }
            ),
            categoryGroupNames: Dictionary(
                budgetStore.categoryGroups.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    @ViewBuilder
    private func widgetView(for widget: DashboardWidget) -> some View {
        // Capture values on the main actor; computation must not read the store.
        let conditionsContext = conditionsContext
        let accounts = budgetStore.accounts
        let categoryGroups = budgetStore.categoryGroups
        let categories = categoryGroups.flatMap(\.categories)
        let payees = budgetStore.payees
        let reportBudgets = reportBudgets
        let customReportConfigs = customReportConfigs
        let firstDayOfWeekIdx = firstDayOfWeekIdx
        let forecastSchedules = forecastSchedules
        let trackingBudgetMonths = trackingBudgetMonths
        let locale = locale
        let today = reportDate
        switch widget {
        case .summary(_, let meta):
            WidgetCard(transactions: reportTransactions, dataVersion: reportDataVersion, loadingHeight: 80) { transactions in
                SummaryEngine.compute(meta: meta, transactions: transactions, today: today, context: conditionsContext)
            } content: { data in
                SummaryWidgetView(displayName: widget.displayName, data: data)
            }
        case .netWorth(_, let meta):
            WidgetCard(transactions: reportTransactions, dataVersion: reportDataVersion, loadingHeight: 180) { transactions in
                NetWorthEngine.compute(meta: meta, transactions: transactions, today: today, context: conditionsContext)
            } content: { data in
                NetWorthWidgetView(displayName: widget.displayName, data: data)
            }
        case .cashFlow(_, let meta):
            WidgetCard(transactions: reportTransactions, dataVersion: reportDataVersion, loadingHeight: 200) { transactions in
                CashFlowEngine.compute(
                    meta: meta,
                    transactions: transactions,
                    offBudgetAccountIds: Set(accounts.filter(\.offBudget).map(\.id)),
                    today: today,
                    context: conditionsContext
                )
            } content: { data in
                CashFlowWidgetView(displayName: widget.displayName, data: data)
            }
        case .spending(_, let meta):
            WidgetCard(transactions: reportTransactions, dataVersion: reportDataVersion, loadingHeight: 120) { transactions in
                SpendingEngine.compute(meta: meta, transactions: Self.spendingScope(transactions, offBudget: conditionsContext.offBudgetAccountIds, income: Set(categories.filter(\.isIncome).map(\.id))),
                                       budgets: reportBudgets.entries,
                                       categories: categories,
                                       categoryGroups: categoryGroups,
                                       today: today, context: conditionsContext)
            } content: { data in
                SpendingWidgetView(
                    displayName: widget.displayName,
                    data: data,
                    comparisonLabel: comparisonLabel(for: meta)
                )
            }
        case .markdown(_, let meta):
            MarkdownWidgetView(meta: meta)
        case .ageOfMoney(_, let meta):
            WidgetCard(transactions: reportTransactions, dataVersion: reportDataVersion, loadingHeight: 160) { transactions in
                AgeOfMoneyEngine.compute(
                    meta: meta,
                    transactions: transactions,
                    today: today,
                    context: conditionsContext,
                    locale: locale
                )
            } content: { data in
                AgeOfMoneyWidgetView(displayName: widget.displayName, data: data)
            }
        case .formula(_, let meta):
            WidgetCard(transactions: reportTransactions, dataVersion: reportDataVersion, loadingHeight: 100) { transactions in
                FormulaEngine.compute(meta: meta, transactions: transactions, today: today, context: conditionsContext)
            } content: { result in
                FormulaWidgetView(displayName: widget.displayName, result: result)
            }
        case .customReport(_, let meta):
            WidgetCard(transactions: reportTransactions, dataVersion: reportDataVersion, loadingHeight: 200) { transactions in
                CustomReportEngine.compute(
                    config: (meta?.id).flatMap { customReportConfigs[$0] },
                    transactions: transactions,
                    reportContext: CustomReportEngine.ReportContext(
                        categories: categories,
                        groups: categoryGroups,
                        offBudgetAccountIds: Set(accounts.filter(\.offBudget).map(\.id)),
                        firstDayOfWeekIdx: firstDayOfWeekIdx,
                        payees: payees,
                        accounts: accounts,
                        budgetEntries: reportBudgets.entries
                    ),
                    filterContext: conditionsContext,
                    today: today, locale: locale
                )
            } content: { data in
                CustomReportWidgetView(data: data)
            }
        case .calendar(_, let meta):
            WidgetCard(transactions: reportTransactions, dataVersion: reportDataVersion, loadingHeight: 200) { transactions in
                CalendarEngine.compute(
                    meta: meta,
                    transactions: transactions,
                    today: today,
                    firstDayOfWeekIdx: firstDayOfWeekIdx,
                    context: conditionsContext
                )
            } content: { data in
                CalendarWidgetView(displayName: widget.displayName, data: data)
            }
        case .crossover(_, let meta):
            WidgetCard(transactions: reportTransactions, dataVersion: reportDataVersion, loadingHeight: 200) { transactions in
                CrossoverEngine.compute(
                    meta: meta,
                    transactions: transactions,
                    categories: categories,
                    accountIds: accounts.map(\.id),
                    today: today
                )
            } content: { data in
                CrossoverWidgetView(displayName: widget.displayName, data: data)
            }
        case .budgetAnalysis(_, let meta):
            WidgetCard(transactions: reportTransactions, dataVersion: reportDataVersion, loadingHeight: 200) { transactions in
                BudgetAnalysisEngine.compute(
                    meta: meta,
                    transactions: transactions,
                    budgets: reportBudgets.entries,
                    categories: categories,
                    categoryGroups: categoryGroups,
                    today: today,
                    context: conditionsContext
                )
            } content: { data in
                BudgetAnalysisWidgetView(displayName: widget.displayName, data: data)
            }
        case .sankey(_, let meta):
            WidgetCard(transactions: reportTransactions, dataVersion: reportDataVersion, loadingHeight: 240) { transactions in
                SankeyEngine.compute(
                    meta: meta,
                    transactions: transactions,
                    categoryGroups: categoryGroups,
                    // ponytail: budgeted-mode envelope aggregates (To Budget /
                    // carryover flows) are omitted — wire per-month toBudget
                    // math if those flows turn out to matter on the card.
                    budget: SankeyBudgetInput(entries: reportBudgets.entries.map {
                        SankeyBudgetInput.Entry(month: $0.month, categoryId: $0.categoryId, amountCents: $0.amountCents)
                    }),
                    today: today,
                    context: conditionsContext,
                    locale: locale
                )
            } content: { data in
                SankeyWidgetView(displayName: widget.displayName, data: data)
            }
        case .balanceForecast(_, let meta):
            let meta = forecastMeta(meta)
            WidgetCard(transactions: reportTransactions, dataVersion: reportDataVersion, loadingHeight: 200) { transactions in
                BalanceForecastEngine.compute(
                    meta: meta,
                    transactions: transactions,
                    schedules: forecastSchedules,
                    trackingBudgetMonths: trackingBudgetMonths,
                    offBudgetAccountIds: Set(accounts.filter(\.offBudget).map(\.id)),
                    transferAccountsByPayeeId: Dictionary(
                        payees.compactMap { payee in
                            payee.transferAccountId.map { (payee.id, $0) }
                        },
                        uniquingKeysWith: { first, _ in first }
                    ),
                    today: today,
                    context: conditionsContext
                )
            } content: { data in
                BalanceForecastWidgetView(displayName: widget.displayName, data: data)
            }
        case .monteCarlo(_, let meta):
            WidgetCard(transactions: reportTransactions, dataVersion: reportDataVersion, loadingHeight: 220) { _ in
                MonteCarloEngine.compute(
                    meta: meta,
                    accountBalances: Dictionary(
                        accounts.map { ($0.id, $0.balance) },
                        uniquingKeysWith: { first, _ in first }
                    )
                )
            } content: { data in
                MonteCarloWidgetView(displayName: widget.displayName, data: data)
            }
        case .unsupported:
            // Filtered out of visibleWidgets; listed in the top notice instead.
            EmptyView()
        }
    }

    /// Upstream's card falls back to the schedules source when the file
    /// isn't a tracking budget (BalanceForecastCard.tsx budgetType check).
    private func forecastMeta(_ meta: BalanceForecastMeta?) -> BalanceForecastMeta? {
        guard let meta, meta.source == .trackingBudget, !reportBudgets.isTracking else { return meta }
        return BalanceForecastMeta(
            name: meta.name, startDate: meta.startDate, endDate: meta.endDate,
            accounts: meta.accounts, conditions: meta.conditions,
            conditionsOp: meta.conditionsOp, timeFrame: meta.timeFrame,
            granularity: meta.granularity, source: .schedules
        )
    }

    /// Match WebUI spending-spreadsheet.ts default exclusions: drop
    /// off-budget accounts and income categories before computing.
    nonisolated static func spendingScope(_ transactions: [Transaction], offBudget: Set<String>, income: Set<String>) -> [Transaction] {
        transactions.filter { transaction in
            !offBudget.contains(transaction.accountId)
                && !(transaction.categoryId.map { income.contains($0) } ?? false)
        }
    }

    private func comparisonLabel(for meta: SpendingMeta?) -> String {
        // nil mode defaults to single-month upstream (SpendingCard.tsx).
        switch meta?.mode ?? .singleMonth {
        case .budget: ReportStrings.text("vs budget", locale: locale)
        case .singleMonth:
            ReportStrings.format("vs %@", meta?.compareTo ?? "prior", locale: locale)
        case .average: ReportStrings.text("vs avg", locale: locale)
        }
    }
}

/// Shared chrome for report widgets: shows the standard loading card until
/// the dashboard-wide transaction fetch lands, then computes the widget's
/// data once per fetch and hands it to `content`.
private struct WidgetCard<Value: Sendable, Content: View>: View {
    @Environment(\.locale) private var locale
    let transactions: [Transaction]?
    let dataVersion: Int
    let loadingHeight: CGFloat
    let compute: @Sendable ([Transaction]) -> Value
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
        .task(id: WidgetComputationRequest(
            transactions: transactions,
            localeIdentifier: locale.identifier,
            dataVersion: dataVersion
        )) {
            guard let transactions else { return }
            do {
                let computed = try await ReportComputation.compute(transactions: transactions, using: compute)
                guard !Task.isCancelled else { return }
                value = computed
            } catch {
                // Computation only throws cancellation; keep the previous result.
            }
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
        .unsupported(id: "3", type: "sankey-card"),
    ])
    .environmentObject(BudgetStore.previewInstance())
}

#Preview("Empty") {
    DashboardView(widgets: [])
        .environmentObject(BudgetStore.previewInstance())
}
