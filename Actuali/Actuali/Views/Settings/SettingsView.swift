import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Data") {
                    NavigationLink {
                        ConnectionDataSettingsView()
                    } label: {
                        Label("Connection & Data", systemImage: "server.rack")
                    }
                }

                Section("Preferences") {
                    NavigationLink {
                        BudgetViewSettingsView()
                    } label: {
                        Label("Budget View", systemImage: "wallet.bifold")
                    }

                    NavigationLink {
                        TransactionAutomationSettingsView()
                    } label: {
                        Label("Transactions & Automation", systemImage: "arrow.left.arrow.right")
                    }

                    NavigationLink {
                        DisplaySettingsView()
                    } label: {
                        Label("Display", systemImage: "iphone")
                    }

                    NavigationLink {
                        PrivacySettingsView()
                    } label: {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                }

                Section("Manage") {
                    NavigationLink {
                        SchedulesListView()
                            .navigationTitle("Scheduled Transactions")
                    } label: {
                        Label("Scheduled Transactions", systemImage: "calendar.badge.clock")
                    }

                    NavigationLink {
                        RulesListView()
                            .navigationTitle("Rules")
                    } label: {
                        Label("Rules", systemImage: "list.bullet.rectangle")
                    }

                    NavigationLink {
                        BankSyncSetupView()
                    } label: {
                        Label("Bank Sync (SimpleFIN)", systemImage: "building.columns")
                    }
                }

                Section("Information") {
                    NavigationLink {
                        AboutSettingsView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
            }
            .readableWidth()
            .navigationTitle("More")
            .contentMargins(.horizontal, 6, for: .scrollContent)
        }
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
