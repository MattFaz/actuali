import SwiftUI

struct SettingsItem {
    let title: String
    let systemImage: String
    let destination: () -> AnyView
}

struct SettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    static var preferencesItems: [SettingsItem] {
        [
            SettingsItem(title: String(localized: "Budget View"), systemImage: "wallet.bifold", destination: { AnyView(BudgetViewSettingsView()) }),
            SettingsItem(title: String(localized: "Display"), systemImage: "iphone", destination: { AnyView(DisplaySettingsView()) }),
            SettingsItem(title: String(localized: "Privacy"), systemImage: "hand.raised", destination: { AnyView(PrivacySettingsView()) }),
            SettingsItem(title: String(localized: "Transactions & Automation"), systemImage: "arrow.left.arrow.right", destination: { AnyView(TransactionAutomationSettingsView()) })
        ].sorted { Self.titlePrecedes($0.title, $1.title) }
    }

    static func manageItems(includeRules: Bool) -> [SettingsItem] {
        var items = [
            SettingsItem(title: String(localized: "Bank Sync (SimpleFIN & Wallet)"), systemImage: "building.columns", destination: { AnyView(BankSyncSetupView()) }),
            SettingsItem(title: String(localized: "Bills & Calendar"), systemImage: "calendar", destination: { AnyView(BillsCalendarView()) }),
            SettingsItem(title: String(localized: "Scheduled Transactions"), systemImage: "calendar.badge.clock", destination: { AnyView(SchedulesListView()) })
        ]
        if includeRules {
            items.append(SettingsItem(title: String(localized: "Rules"), systemImage: "list.bullet.rectangle", destination: { AnyView(RulesListView()) }))
        }
        return items.sorted { Self.titlePrecedes($0.title, $1.title) }
    }

    nonisolated static func titlePrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Data")) {
                    NavigationLink {
                        ConnectionDataSettingsView()
                    } label: {
                        Label(String(localized: "Connection & Data"), systemImage: "server.rack")
                    }
                }
                Section(String(localized: "Preferences")) {
                    ForEach(Self.preferencesItems, id: \.title) { item in
                        NavigationLink {
                            item.destination()
                        } label: {
                            Label(item.title, systemImage: item.systemImage)
                        }
                    }
                }
                Section(String(localized: "Manage")) {
                    ForEach(Self.manageItems(includeRules: budgetStore.currentBudgetId != nil), id: \.title) { item in
                        NavigationLink {
                            item.destination()
                        } label: {
                            Label(item.title, systemImage: item.systemImage)
                        }
                    }

                    NavigationLink {
                        HistoryView()
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                }
                Section(String(localized: "Information")) {
                    NavigationLink {
                        AboutSettingsView()
                    } label: {
                        Label(String(localized: "About"), systemImage: "info.circle")
                    }
                }
            }
            .readableWidth()
            .navigationTitle(String(localized: "navigation.settings"))
            .contentMargins(.horizontal, 6, for: .scrollContent)
        }
        // Keep the store-wide loading indicator above the navigation stack so
        // operations started from any destination remain covered, not only
        // work launched from the hub form.
        .overlay {
            if budgetStore.isLoading {
                ProgressView()
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(BudgetStore.previewInstance())
}
