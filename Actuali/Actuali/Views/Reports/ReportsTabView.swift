import SwiftUI

struct ReportsTabView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @State private var pages: [DashboardPage] = []
    @State private var selectedPageId: String?
    @State private var widgets: [DashboardWidget] = []
    @State private var loadError: String?
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            Group {
                if !hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView(
                        "Could not load reports",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if budgetStore.databaseForLogger == nil {
                    ContentUnavailableView(
                        "No budget open",
                        systemImage: "chart.bar.xaxis",
                        description: Text("Open or sync a budget to see reports.")
                    )
                } else {
                    // Keyed so per-widget @State (computed card values) resets
                    // when switching dashboards instead of showing the
                    // previous dashboard's numbers.
                    DashboardView(widgets: widgets)
                        .id(selectedPageId)
                }
            }
            .navigationTitle("Reports")
            .toolbar {
                if pages.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        dashboardPicker
                    }
                }
            }
            // Keyed to the open database so the initial load re-runs when
            // the budget finishes opening (launching straight onto this tab
            // races loadLocalBudget) and when the budget is switched.
            .task(id: budgetStore.databaseForLogger.map(ObjectIdentifier.init)) { await reload() }
            .refreshable {
                await budgetStore.sync()
                await reload()
            }
        }
        .initialSyncBanner()
    }

    /// Menu listing every live dashboard page, shown only when the budget
    /// actually has more than one (the web app's sidebar equivalent).
    private var dashboardPicker: some View {
        Menu {
            Picker("Dashboard", selection: Binding(
                get: { selectedPageId ?? "" },
                set: { newId in
                    selectedPageId = newId
                    Task { await reload() }
                }
            )) {
                ForEach(pages) { page in
                    Text(displayName(for: page)).tag(page.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(pages.first { $0.id == selectedPageId }.map(displayName(for:)) ?? "Dashboard")
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
        }
        .accessibilityLabel("Switch dashboard")
    }

    private func displayName(for page: DashboardPage) -> String {
        page.name.isEmpty ? "Untitled" : page.name
    }

    /// Which page to show: a still-live explicit selection wins, otherwise
    /// the first live page (the web's ReportsDashboardRouter redirects to
    /// dashboardPages[0]), otherwise nil so the pre-pages pageless fallback
    /// applies.
    static func resolvePageId(selected: String?, pages: [DashboardPage]) -> String? {
        if let selected, pages.contains(where: { $0.id == selected }) {
            return selected
        }
        return pages.first?.id
    }

    private func reload() async {
        guard let database = budgetStore.databaseForLogger else {
            self.hasLoaded = true
            return
        }
        do {
            let fetchedPages = try await database.fetchDashboardPages()
            let pageId = Self.resolvePageId(selected: selectedPageId, pages: fetchedPages)
            let fetched = try await database.fetchWidgets(pageId: pageId)
            self.pages = fetchedPages
            self.selectedPageId = pageId
            self.widgets = fetched
            self.loadError = nil
        } catch is CancellationError {
            // The hosting task was torn down (tab switch, refresh gesture
            // cancelled). Keep whatever is on screen; the next appearance
            // reloads.
            return
        } catch {
            self.loadError = error.localizedDescription
        }
        self.hasLoaded = true
    }
}
