import SwiftUI

struct ReportsLoadRequest: Equatable {
    let databaseID: ObjectIdentifier?
    let generation: Int
}

struct ReportsTabView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    @State private var pages: [DashboardPage] = []
    @State private var selectedPageId: String?
    @State private var widgets: [DashboardWidget] = []
    /// The page `widgets` actually came from, which is not `selectedPageId`:
    /// that one flips the instant the picker is tapped, while the widgets
    /// arrive a fetch later. Keep it alongside the fetched widgets when resolving dashboard identity.
    @State private var loadedPageId: String?
    @State private var dashboardGeneration = 0
    @State private var loadError: String?
    @State private var hasLoaded = false
    @State private var loadGeneration = 0

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
                        // Recreate cards when the page or widget definitions change,
                        // so their inputs and computed state belong to that dashboard.
                        DashboardView(widgets: widgets)
                            .id(dashboardGeneration)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // Keyed to the open database so the initial load re-runs when
            // the budget finishes opening (launching straight onto this tab
            // races loadLocalBudget) and when the budget is switched.
            .task(id: currentLoadRequest) {
                let request = currentLoadRequest
                guard let database = budgetStore.databaseForLogger else {
                    await reload(request: request)
                    return
                }
                do {
                    for try await _ in database.dashboardChanges() {
                        await reload(request: request)
                    }
                } catch {
                    guard Self.shouldPublish(request: request, currentRequest: currentLoadRequest,
                                             taskIsCancelled: Task.isCancelled) else { return }
                    loadError = error.localizedDescription
                    hasLoaded = true
                }
            }
            // This is a resident tab: nothing rebuilds it on the way back from
            // Settings, and `reload` has already written the resolved page into
            // `selectedPageId` — which outranks the new default. So changing the
            // setting has to switch the dashboard itself, or it appears to do
            // nothing until the next launch. Clearing it (nil) re-resolves to
            // the first page.
            .onChange(of: budgetStore.defaultDashboardPageId) { _, newValue in
                selectedPageId = newValue
                requestReload()
            }
            .refreshable {
                await budgetStore.sync()
                requestReload()
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
                    requestReload()
                }
            )) {
                ForEach(pages) { page in
                    Text(displayName(for: page)).tag(page.id)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(pages.first { $0.id == selectedPageId }.map(displayName(for:))
                    ?? ReportStrings.text("Dashboard", locale: locale))
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
        page.name.isEmpty ? ReportStrings.text("Untitled", locale: locale) : page.name
    }

    private var currentLoadRequest: ReportsLoadRequest {
        ReportsLoadRequest(
            databaseID: budgetStore.databaseForLogger.map(ObjectIdentifier.init),
            generation: loadGeneration
        )
    }

    private func requestReload() {
        loadGeneration += 1
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

    nonisolated static func dashboardIdentityChanged(
        loadedWidgets: [DashboardWidget], fetchedWidgets: [DashboardWidget],
        loadedPageId: String?, fetchedPageId: String?
    ) -> Bool {
        loadedWidgets != fetchedWidgets || loadedPageId != fetchedPageId
    }

    nonisolated static func shouldPublish(
        request: ReportsLoadRequest,
        currentRequest: ReportsLoadRequest,
        taskIsCancelled: Bool
    ) -> Bool {
        !taskIsCancelled && request == currentRequest
    }

    private func reload(request: ReportsLoadRequest) async {
        guard let database = budgetStore.databaseForLogger else {
            guard Self.shouldPublish(
                request: request,
                currentRequest: currentLoadRequest,
                taskIsCancelled: Task.isCancelled
            ) else { return }
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
            guard Self.shouldPublish(
                request: request,
                currentRequest: currentLoadRequest,
                taskIsCancelled: Task.isCancelled
            ) else { return }
            self.pages = fetchedPages
            self.selectedPageId = pageId
            if Self.dashboardIdentityChanged(loadedWidgets: widgets, fetchedWidgets: fetched,
                                             loadedPageId: loadedPageId, fetchedPageId: pageId) {
                dashboardGeneration += 1
            }
            self.widgets = fetched
            self.loadedPageId = pageId
            self.loadError = nil
        } catch is CancellationError {
            // The hosting task was torn down (tab switch, refresh gesture
            // cancelled). Keep whatever is on screen; the next appearance
            // reloads.
            return
        } catch {
            guard Self.shouldPublish(
                request: request,
                currentRequest: currentLoadRequest,
                taskIsCancelled: Task.isCancelled
            ) else { return }
            self.loadError = error.localizedDescription
        }
        guard Self.shouldPublish(
            request: request,
            currentRequest: currentLoadRequest,
            taskIsCancelled: Task.isCancelled
        ) else { return }
        self.hasLoaded = true
    }
}
