import SwiftUI

struct PrivacySettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    var body: some View {
        Form {
            Section {
                Toggle("Hide Balances", isOn: $budgetStore.hideBalances)
            } header: {
                Text("Balance Visibility")
            } footer: {
                Text("Hide Balances masks amounts across the app while leaving amount entry and reconciliation visible.")
            }
        }
        .readableWidth()
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
    }
}
