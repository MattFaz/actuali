import SwiftUI

struct AccountsListView: View {
    @EnvironmentObject var budgetStore: BudgetStore

    var totalBalance: Int {
        budgetStore.accounts.reduce(0) { $0 + $1.balance }
    }

    var onBudgetAccounts: [Account] {
        budgetStore.accounts.filter { !$0.offBudget && !$0.closed }
    }

    var offBudgetAccounts: [Account] {
        budgetStore.accounts.filter { $0.offBudget && !$0.closed }
    }

    var body: some View {
        NavigationStack {
            Group {
                if budgetStore.accounts.isEmpty && !budgetStore.isLoading {
                    if budgetStore.isConnected && budgetStore.currentBudgetId == nil {
                        ContentUnavailableView(
                            "Select a Budget",
                            systemImage: "dollarsign.circle",
                            description: Text("You're connected. Choose a budget in Settings to load it here.")
                        )
                    } else {
                        ContentUnavailableView(
                            "No Budget Loaded",
                            systemImage: "dollarsign.circle",
                            description: Text("Go to Settings to connect to your Actual Budget server")
                        )
                    }
                } else {
                    List {
                        Section {
                            NavigationLink {
                                TransactionsListView()
                            } label: {
                                HStack {
                                    Text("All Accounts")
                                        .font(.headline)
                                    Spacer()
                                    Text(budgetStore.formatCurrency(totalBalance))
                                        .font(.headline)
                                        .foregroundColor(totalBalance > 0 ? .green : (totalBalance < 0 ? .red : .primary))
                                }
                            }
                        }

                        if !onBudgetAccounts.isEmpty {
                            Section("On Budget") {
                                ForEach(onBudgetAccounts) { account in
                                    NavigationLink(value: account) {
                                        AccountRow(account: account)
                                    }
                                }
                            }
                        }

                        if !offBudgetAccounts.isEmpty {
                            Section("Off Budget") {
                                ForEach(offBudgetAccounts) { account in
                                    NavigationLink(value: account) {
                                        AccountRow(account: account)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    SyncStatusView(state: budgetStore.syncState)
                }
            }
            .navigationDestination(for: Account.self) { account in
                AccountDetailView(account: account)
            }
            .refreshable {
                await budgetStore.sync()
            }
            .overlay {
                if budgetStore.isLoading {
                    ProgressView()
                }
            }
        }
    }

}

struct AccountRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let account: Account

    var body: some View {
        HStack {
            Text(account.name)
                .font(.body)
            Spacer()
            Text(budgetStore.formatCurrency(account.balance))
                .foregroundColor(account.balance > 0 ? .green : (account.balance < 0 ? .red : .primary))
        }
    }
}

#Preview {
    AccountsListView()
        .environmentObject(BudgetStore.previewInstance())
}
