import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

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
                    NavigationLink {
                        BudgetViewSettingsView()
                    } label: {
                        Label(String(localized: "Budget View"), systemImage: "wallet.bifold")
                    }

                    NavigationLink {
                        TransactionAutomationSettingsView()
                    } label: {
                        Label(String(localized: "Transactions & Automation"), systemImage: "arrow.left.arrow.right")
                    }

                    NavigationLink {
                        DisplaySettingsView()
                    } label: {
                        Label(String(localized: "Display"), systemImage: "iphone")
                    }

                    NavigationLink {
                        PrivacySettingsView()
                    } label: {
                        Label(String(localized: "Privacy"), systemImage: "hand.raised")
                    }
                }

                Section(String(localized: "Manage")) {
                    NavigationLink {
                        SchedulesListView()
                    } label: {
                        Label(String(localized: "Scheduled Transactions"), systemImage: "calendar.badge.clock")
                    }

                    if budgetStore.currentBudgetId != nil {
                        NavigationLink {
                            RulesListView()
                        } label: {
                            Label(String(localized: "Rules"), systemImage: "list.bullet.rectangle")
                        }
                    }

                    NavigationLink {
                        BankSyncSetupView()
                    } label: {
                        Label(String(localized: "Bank Sync (SimpleFIN & Wallet)"), systemImage: "building.columns")
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
