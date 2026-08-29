import SwiftUI

struct ManageSettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    SchedulesListView()
                } label: {
                    Label("Scheduled Transactions", systemImage: "calendar.badge.clock")
                }

                if budgetStore.currentBudgetId != nil {
                    NavigationLink {
                        RulesListView()
                    } label: {
                        Label("Rules", systemImage: "list.bullet.rectangle")
                    }
                }

                NavigationLink {
                    BankSyncSetupView()
                } label: {
                    Label("Bank Sync (SimpleFIN)", systemImage: "building.columns")
                }
            } footer: {
                Text("Scheduled transactions that are due are posted automatically when the app opens — the same as opening the Actual web app. Transactions are created on your server. Connect SimpleFIN to import transactions straight from your bank.")
            }
        }
        .readableWidth()
        .navigationTitle("Manage")
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
    }
}
