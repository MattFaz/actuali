import SwiftUI

struct ReportsTabView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @State private var pages: [DashboardPage] = []
    @State private var selectedPageId: String?
    @State private var widgets: [DashboardWidget] = []
    /// The page `widgets` actually came from, which is not `selectedPageId`:
    /// that one flips the instant the picker is tapped, while the widgets
    /// arrive a fetch later. See the dashboard's `.id` for what goes wrong
    /// when the two are conflated.
    @State private var loadedPageId: String?
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
                    VStack(spacing: 0) {
                        dashboardPicker
                            // Lined up with the dashboard cards below, which
                            // carry 6 pt of horizontal padding of their own.
                            .padding(.horizontal, 6)
                            .padding(.top, 8)
                        // Keyed so per-widget @State (computed card values)
                        // resets when switching dashboards instead of showing
                        // the previous dashboard's numbers. Keyed to the page
                        // the widgets came from, not the selection: keying on
                        // the selection re-creates the dashboard around the
                        // outgoing page's widgets, and DashboardView's load
                        // runs once per identity — so it would fetch the
                        // inputs that widget set needs and never re-run for
                        // the widgets that actually land.
                        DashboardView(widgets: widgets)
                            .id([loadedPageId ?? ""] + widgets.map(\.id))
                    }
                }
            }
            // The dashboard picker is the page's header now, so the title
            // stays out of its way in the compact bar.
            .navigationTitle("Reports")
            .navigationBarTitleDisplayMode(.inline)
            // Keyed to the open database so the initial load re-runs when
            // the budget finishes opening (launching straight onto this tab
            // races loadLocalBudget) and when the budget is switched.
            .task(id: budgetStore.databaseForLogger.map(ObjectIdentifier.init)) { await reload() }
            // This is a resident tab: nothing rebuilds it on the way back from
            // Settings, and `reload` has already written the resolved page into
            // `selectedPageId` — which outranks the new default. So changing the
            // setting has to switch the dashboard itself, or it appears to do
            // nothing until the next launch. Clearing it (nil) re-resolves to the
            // first page.
            .onChange(of: budgetStore.defaultDashboardPageId) { _, newValue in
                selectedPageId = newValue
                Task { await reload() }
            }
            // Sync can replace the widget set while staying on the same page.
            // Changing the dashboard identity below recreates DashboardView so
            // its input load restarts for the newly synced cards as well.
            .onChange(of: budgetStore.dataVersion) { _, _ in
                Task { await reload() }
            }
            .refreshable {
                await budgetStore.sync()
                await reload()
            }
        }
        .initialSyncBanner()
    }

    /// Full-width dropdown naming the dashboard on screen (the web app's
    /// sidebar equivalent). Shown whatever the page count: with a single page
    /// it still labels what you're looking at, and it's disabled only for the
    /// pre-dashboard-pages budgets that have no pages to switch between.
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
            HStack(spacing: 8) {
                Text(pages.first { $0.id == selectedPageId }.map(displayName(for:)) ?? "Dashboard")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            // Same fill and radius as the widget cards it sits above.
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(pages.isEmpty)
        .accessibilityLabel("Switch dashboard")
    }

    private func displayName(for page: DashboardPage) -> String {
        page.name.isEmpty ? "Untitled" : page.name
    }

    /// Which page to show: a still-live explicit selection wins, then the
    /// dashboard configured in Settings (GH #223), otherwise the first live
    /// page (the web's ReportsDashboardRouter redirects to dashboardPages[0]),
    /// otherwise nil so the pre-pages pageless fallback applies.
    nonisolated static func resolvePageId(
        selected: String?,
        configuredDefault: String? = nil,
        pages: [DashboardPage]
    ) -> String? {
        if let selected, pages.contains(where: { $0.id == selected }) {
            return selected
        }
        if let configuredDefault, pages.contains(where: { $0.id == configuredDefault }) {
            return configuredDefault
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
            let pageId = Self.resolvePageId(
                selected: selectedPageId,
                configuredDefault: budgetStore.defaultDashboardPageId,
                pages: fetchedPages
            )
            let fetched = try await database.fetchWidgets(pageId: pageId)
            self.pages = fetchedPages
            self.selectedPageId = pageId
            self.widgets = fetched
            // Same render pass as the widgets it identifies, so the dashboard
            // is re-created around them rather than around their predecessor.
            self.loadedPageId = pageId
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
