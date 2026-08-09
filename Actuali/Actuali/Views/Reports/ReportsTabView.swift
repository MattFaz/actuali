import SwiftUI

struct ReportsTabView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
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
                    DashboardView(widgets: widgets)
                }
            }
            .navigationTitle("Reports")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    BalanceVisibilityButton()
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
    }

    private func reload() async {
        guard let database = budgetStore.databaseForLogger else {
            self.hasLoaded = true
            return
        }
        do {
            let fetched = try await database.fetchWidgets()
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
