import SwiftUI

struct ManageSettingsView: View {
    var body: some View {
        Form {
            Section {
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
        }
        .readableWidth()
        .navigationTitle("Manage")
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
    }
}

#Preview {
    NavigationStack {
        ManageSettingsView()
    }
}
