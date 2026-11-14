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
                        ForEach(Self.rows(visibleWidgets), id: \.first?.id) { row in
                            if row.count == 1 {
                                widgetView(for: row[0])
                            } else {
                                // Sized to the taller of the pair; the fill behind
                                // each card is the card's own, so the shorter one
                                // reads as the same height.
                                HStack(spacing: 12) {
                                    ForEach(row, id: \.id) { widget in
                                        widgetView(for: widget)
                                            .frame(maxHeight: .infinity, alignment: .top)
                                            .background(Color(.secondarySystemBackground))
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                }
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
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

    /// iPhone rows: single-number widgets (Summary, Formula) sit two to a row
    /// where they're neighbours, since one number doesn't need the full
    /// width. Everything else gets a row of its own.
    nonisolated static func rows(_ widgets: [DashboardWidget]) -> [[DashboardWidget]] {
        var rows: [[DashboardWidget]] = []
        var lastIsOpenPair = false
        for widget in widgets {
            let isTile = switch widget {
            case .summary, .formula: true
            default: false
            }
            if isTile, lastIsOpenPair {
                rows[rows.count - 1].append(widget)
                lastIsOpenPair = false
            } else {
                rows.append([widget])
                lastIsOpenPair = isTile
            }
        }
        return rows
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
                // Spending's detail page compares against the budget
                // whatever mode the card is in.
                case .budgetAnalysis, .sankey, .balanceForecast, .spending: true
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
            detailCard(widget, meta: meta, loadingHeight: 180, ranged: ranged(meta)) { meta, transactions in
                NetWorthEngine.compute(meta: meta, transactions: transactions, today: today, context: conditionsContext)
            } model: { data in
                data.chartDetail(name: widget.displayName, locale: locale)
            } card: { data, detail in
                // The glance card when there is something to chart; the
                // widget's own card (and its empty state) when there isn't.
                if let detail {
                    ReportGlanceCard(detail: detail)
                } else {
                    NetWorthWidgetView(displayName: widget.displayName, data: data)
                }
            } detail: {
                ReportChartDetailView(detail: $0)
            }
        case .cashFlow(_, let meta):
            detailCard(widget, meta: meta, loadingHeight: 200, ranged: ranged(meta)) { meta, transactions in
                CashFlowEngine.compute(
                    meta: meta,
                    transactions: transactions,
                    offBudgetAccountIds: Set(accounts.filter(\.offBudget).map(\.id)),
                    today: today,
                    context: conditionsContext
                )
            } model: { data in
                data.chartDetail(name: widget.displayName, locale: locale)
            } card: { data, detail in
                // The glance card when there is something to chart; the
                // widget's own card (and its empty state) when there isn't.
                if let detail {
                    ReportGlanceCard(detail: detail)
                } else {
                    CashFlowWidgetView(displayName: widget.displayName, data: data)
                }
            } detail: {
                ReportChartDetailView(detail: $0)
            }
        case .spending(_, let meta):
            // ponytail: all three comparisons run on every dashboard load so
            // the detail page opens at once. Ceiling: three engine passes and
            // a budget fetch per Spending card, where the card shows one.
            // Compute the other two behind the page if that starts to cost.
            detailCard(widget, meta: meta, loadingHeight: 120) { meta, transactions in
                let scoped = Self.spendingScope(transactions, offBudget: conditionsContext.offBudgetAccountIds, income: Set(categories.filter(\.isIncome).map(\.id)))
                return SpendingComparisons.compute(meta: meta) { meta in
                    SpendingEngine.compute(meta: meta, transactions: scoped,
                                           budgets: reportBudgets.entries,
                                           categories: categories,
                                           categoryGroups: categoryGroups,
                                           today: today, context: conditionsContext)
                }
            } model: { comparisons in
                comparisons
            } card: { comparisons, _ in
                SpendingWidgetView(
                    displayName: widget.displayName,
                    data: comparisons.card,
                    comparisonLabel: comparisonLabel(for: meta)
                )
            } detail: { comparisons in
                SpendingDetailView(
                    displayName: widget.displayName,
                    comparisons: comparisons,
                    labels: SpendingComparisons.modes.map { comparisonLabel(mode: $0, compareTo: meta?.compareTo) }
                )
            }
        case .markdown(_, let meta):
            MarkdownWidgetView(meta: meta)
        case .ageOfMoney(_, let meta):
            detailCard(widget, meta: meta, loadingHeight: 160, ranged: ranged(meta)) { meta, transactions in
                AgeOfMoneyEngine.compute(
                    meta: meta,
                    transactions: transactions,
                    today: today,
                    context: conditionsContext,
                    locale: locale
                )
            } model: { data in
                data.chartDetail(name: widget.displayName, locale: locale)
            } card: { data, detail in
                // The glance card when there is something to chart; the
                // widget's own card (and its empty state) when there isn't.
                if let detail {
                    ReportGlanceCard(detail: detail)
                } else {
                    AgeOfMoneyWidgetView(displayName: widget.displayName, data: data)
                }
            } detail: {
                ReportChartDetailView(detail: $0)
            }
        case .formula(_, let meta):
            WidgetCard(transactions: reportTransactions, dataVersion: reportDataVersion, loadingHeight: 100) { transactions in
                FormulaEngine.compute(meta: meta, transactions: transactions, today: today, context: conditionsContext)
            } content: { result in
                FormulaWidgetView(displayName: widget.displayName, result: result)
            }
        case .customReport(_, let meta):
            let config = (meta?.id).flatMap { customReportConfigs[$0] }
            detailCard(
                widget, meta: config, loadingHeight: 200,
                ranged: config == nil ? nil : { (config: CustomReportConfig?, range: ReportDetailRange) in config?.ranged(range) }
            ) { config, transactions in
                CustomReportEngine.compute(
                    config: config,
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
            } model: { data in
                // A chart to scrub, or a donut or table to list in full.
                data.chartDetail(locale: locale).map(CustomReportPage.chart) ?? data.breakdown.map(CustomReportPage.breakdown)
            } card: { data, page in
                // The glance card when there is something to chart; the
                // widget's own card (and its empty state) when there isn't.
                if case .chart(let detail) = page {
                    ReportGlanceCard(detail: detail)
                } else {
                    CustomReportWidgetView(data: data)
                }
            } detail: { page in
                switch page {
                case .chart(let detail): ReportChartDetailView(detail: detail)
                case .breakdown(let breakdown): ReportBreakdownDetailView(breakdown: breakdown)
                }
            }
        case .calendar(_, let meta):
            detailCard(widget, meta: meta, loadingHeight: 200, ranged: ranged(meta)) { meta, transactions in
                CalendarEngine.compute(
                    meta: meta,
                    transactions: transactions,
                    today: today,
                    firstDayOfWeekIdx: firstDayOfWeekIdx,
                    context: conditionsContext
                )
            } model: { data in
                data.months.isEmpty ? nil : data
            } card: { data, _ in
                CalendarWidgetView(displayName: widget.displayName, data: data)
            } detail: { data in
                CalendarDetailView(displayName: widget.displayName, data: data)
            }
        case .crossover(_, let meta):
            detailCard(widget, meta: meta, loadingHeight: 200) { meta, transactions in
                CrossoverEngine.compute(
                    meta: meta,
                    transactions: transactions,
                    categories: categories,
                    accountIds: accounts.map(\.id),
                    today: today
                )
            } model: { data in
                data.chartDetail(name: widget.displayName, locale: locale)
            } card: { data, detail in
                // The glance card when there is something to chart; the
                // widget's own card (and its empty state) when there isn't.
                if let detail {
                    ReportGlanceCard(detail: detail)
                } else {
                    CrossoverWidgetView(displayName: widget.displayName, data: data)
                }
            } detail: {
                ReportChartDetailView(detail: $0)
            }
        case .budgetAnalysis(_, let meta):
            detailCard(widget, meta: meta, loadingHeight: 200, ranged: ranged(meta)) { meta, transactions in
                BudgetAnalysisEngine.compute(
                    meta: meta,
                    transactions: transactions,
                    budgets: reportBudgets.entries,
                    categories: categories,
                    categoryGroups: categoryGroups,
                    today: today,
                    context: conditionsContext
                )
            } model: { data in
                data.chartDetail(name: widget.displayName, locale: locale)
            } card: { data, detail in
                // The glance card when there is something to chart; the
                // widget's own card (and its empty state) when there isn't.
                if let detail {
                    ReportGlanceCard(detail: detail)
                } else {
                    BudgetAnalysisWidgetView(displayName: widget.displayName, data: data)
                }
            } detail: {
                ReportChartDetailView(detail: $0)
            }
        case .sankey(_, let meta):
            detailCard(widget, meta: meta, loadingHeight: 240, ranged: ranged(meta)) { meta, transactions in
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
            } model: { data in
                data.hasDrawableFlows ? data : nil
            } card: { data, _ in
                SankeyWidgetView(displayName: widget.displayName, data: data)
            } detail: { data in
                SankeyDetailView(displayName: widget.displayName, data: data)
            }
        case .balanceForecast(_, let meta):
            // No range picker: the forecast runs forward from today.
            detailCard(widget, meta: forecastMeta(meta), loadingHeight: 200) { meta, transactions in
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
            } model: { data in
                data.chartDetail(
                    name: widget.displayName,
                    payeeNames: Dictionary(payees.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
                    locale: locale
                )
            } card: { data, detail in
                // The glance card when there is something to chart; the
                // widget's own card (and its empty state) when there isn't.
                if let detail {
                    ReportGlanceCard(detail: detail)
                } else {
                    BalanceForecastWidgetView(displayName: widget.displayName, data: data)
                }
            } detail: {
                ReportChartDetailView(detail: $0)
            }
        case .monteCarlo(_, let meta):
            detailCard(widget, meta: meta, loadingHeight: 220) { meta, _ in
                MonteCarloEngine.compute(
                    meta: meta,
                    accountBalances: Dictionary(
                        accounts.map { ($0.id, $0.balance) },
                        uniquingKeysWith: { first, _ in first }
                    )
                )
            } model: { data in
                data.chartDetail(name: widget.displayName, locale: locale)
            } card: { data, detail in
                // The glance card when there is something to chart; the
                // widget's own card (and its empty state) when there isn't.
                if let detail {
                    ReportGlanceCard(detail: detail)
                } else {
                    MonteCarloWidgetView(displayName: widget.displayName, data: data)
                }
            } detail: {
                ReportChartDetailView(detail: $0)
            }
        case .unsupported:
            // Filtered out of visibleWidgets; listed in the top notice instead.
            EmptyView()
        }
    }

    /// A card that opens a detail page. `ranged` recomputes the widget over a
    /// range picked there; leave it nil when the widget has no range to move.
    /// `model` is what both the card and the page draw from; a card with
    /// nothing to show in detail (`model` returns nil) stays a plain card.
    /// What a custom report's page shows: a chart, or a donut or table in full.
    private enum CustomReportPage {
        case chart(ReportChartDetail)
        case breakdown(ReportBreakdown)
    }

    private func detailCard<Meta: Sendable, Value: Sendable, Model>(
        _ widget: DashboardWidget,
        meta: Meta,
        loadingHeight: CGFloat,
        ranged: (@Sendable (Meta, ReportDetailRange) -> Meta)? = nil,
        compute: @escaping @Sendable (Meta, [Transaction]) -> Value,
        model: @escaping (Value) -> Model?,
        @ViewBuilder card: @escaping (Value, Model?) -> some View,
        @ViewBuilder detail: @escaping (Model) -> some View
    ) -> some View {
        let transactions = reportTransactions
        let locale = locale
        return WidgetCard(transactions: transactions, dataVersion: reportDataVersion, loadingHeight: loadingHeight) {
            compute(meta, $0)
        } content: { value in
            // Built once per pass, for both the card and the link.
            let page = model(value)
            if page == nil {
                card(value, nil)
            } else {
                NavigationLink {
                    ReportRangedDetail(
                        initial: value,
                        transactions: transactions ?? [],
                        recompute: ranged.map { ranged in
                            { @Sendable range, transactions in compute(ranged(meta, range), transactions) }
                        }
                    ) { value in
                        if let page = model(value) {
                            detail(page)
                        } else {
                            ContentUnavailableView(
                                ReportStrings.text("No data in range", locale: locale),
                                systemImage: "chart.bar.xaxis"
                            )
                            .toolbar(.visible, for: .navigationBar)
                        }
                    }
                } label: {
                    card(value, page).environment(\.reportCardLinksToDetail, true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reportCard.\(widget.id)")
            }
        }
    }

    private func ranged<Meta: TimeFramedMeta>(_ meta: Meta?) -> (@Sendable (Meta?, ReportDetailRange) -> Meta?)? {
        let today = reportDate
        guard meta != nil else { return nil }
        return { (meta: Meta?, range: ReportDetailRange) -> Meta? in meta?.ranged(range, asOf: today) }
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
        comparisonLabel(mode: meta?.mode ?? .singleMonth, compareTo: meta?.compareTo)
    }

    private func comparisonLabel(mode: SpendingMeta.Mode, compareTo: String?) -> String {
        switch mode {
        case .budget: ReportStrings.text("vs budget", locale: locale)
        case .singleMonth:
            ReportStrings.format("vs %@", compareTo ?? "prior", locale: locale)
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
