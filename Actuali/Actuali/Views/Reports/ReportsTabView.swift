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
                            .padding(.horizontal, 6)
                            .padding(.top, 8)
                        DashboardView(widgets: widgets)
                            .id(loadedPageId)
                    }
                }
            }
            .navigationTitle("Reports")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: budgetStore.databaseForLogger.map(ObjectIdentifier.init)) {
                await reload()
            }
            // Reload the dashboard whenever sync or another write changes the
            // budget data. This is necessary for Formula cards because the
            // formula/query metadata is stored in the dashboard table and the
            // Reports tab is resident instead of being recreated on every tab
            // switch. It also keeps static time-frame changes made in the web
            // app (for example changing a card from July to June) visible
            // without requiring an app restart or manual pull-to-refresh.
            .onChange(of: budgetStore.dataVersion) { _, _ in
                Task { await reload() }
            }
            .onChange(of: budgetStore.defaultDashboardPageId) { _, newValue in
                selectedPageId = newValue
                Task { await reload() }
            }
            .refreshable {
                await budgetStore.sync()
                await reload()
            }
        }
        .initialSyncBanner()
    }

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
            self.loadedPageId = pageId
            self.loadError = nil
        } catch is CancellationError {
            return
        } catch {
            self.loadError = error.localizedDescription
        }
        self.hasLoaded = true
    }
}
