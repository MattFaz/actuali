import SwiftUI

struct TransactionAutomationSettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Default Account", selection: $budgetStore.defaultAccountId) {
                    Text("None").tag(nil as String?)
                    ForEach(budgetStore.accounts.filter { !$0.closed }, id: \.id) { account in
                        Text(account.name).tag(account.id as String?)
                    }
                }
            }
            Section("Automations") {
                NavigationLink {
                    CategoryFundingAutomationView()
                } label: {
                    Label("Category Funding Settings", systemImage: "arrow.up.circle")
                }
                NavigationLink {
                    WalletAutomationView()
                } label: {
                    Label("Log Wallet Payments Automatically", systemImage: "wallet.pass")
                }
            }
        }
        .navigationTitle("Transactions & Automation")
        .navigationBarTitleDisplayMode(.inline)
    }
}