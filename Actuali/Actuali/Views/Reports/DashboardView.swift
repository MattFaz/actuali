import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let widgets: [DashboardWidget]

    /// Report transactions fetched once per dashboard load and shared by all
    /// widgets (previously each widget fetched the full set independently).
    /// nil while the fetch is in flight.
    @State private var reportTransactions: [Transaction]?

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

    @ViewBuilder
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
            // Keyed to both the budget data and widget set: a sync can change
            // dashboard widgets without changing the page identity.
            .task(id: "\(budgetStore.dataVersion)|\(widgets.map(\.id).joined(separator: ","))") {
                await loadTransactions()
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
        firstDayOfWeekIdx = (try? await database.fetchFirstDayOfWeekIdx()) ?? 0
        let needsBudgets = widgets.contains {
            switch $0 {
            case .budgetAnalysis, .sankey, .balanceForecast: return true
            case .spending(_, let meta): return meta?.mode == .budget
            default: return false
            }
        }
        if needsBudgets {
            reportBudgets = (try? await database.fetchBudgetDataForReports()) ?? BudgetDatabase.ReportBudgetData()
        }
        let needsForecast = widgets.contains {
            if case .balanceForecast = $0 { return true }
            return false
        }
        if needsForecast {
            forecastSchedules = (try? await database.fetchForecastSchedules()) ?? []
            trackingBudgetMonths = (try? await database.fetchTrackingBudgetMonths()) ?? []
        }
        reportTransactions = (try? await database.fetchTransactionsForReports()) ?? []
    }
