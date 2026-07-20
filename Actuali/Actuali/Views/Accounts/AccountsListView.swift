import SwiftUI

/// Value-based route for the All Accounts transaction list, so the
/// notification tap can programmatically reset the stack onto it.
struct AllAccountsRoute: Hashable {}

struct AccountsListView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @StateObject private var notificationRouter = NotificationRouter.shared
    @State private var path = NavigationPath()

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
        NavigationStack(path: $path) {
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
                            NavigationLink(value: AllAccountsRoute()) {
                                HStack {
                                    Text("All Accounts")
                                        .font(.headline)
                                    Spacer()
                                    Text(budgetStore.displayBalance(totalBalance))
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
                ToolbarItem(placement: .topBarTrailing) {
                    BalanceVisibilityButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    SyncStatusView(state: budgetStore.syncState)
                }
            }
            .navigationDestination(for: Account.self) { account in
                AccountDetailView(account: account)
            }
            .navigationDestination(for: AllAccountsRoute.self) { _ in
                TransactionsListView()
            }
            .onAppear(perform: consumePendingAllAccountsNavigation)
            .onChange(of: notificationRouter.pendingAllAccountsNavigation) { _, pending in
                if pending { consumePendingAllAccountsNavigation() }
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

    /// Tapping a success notification lands here: jump the stack straight to
    /// All Accounts (replacing anything the user had pushed) and clear the
    /// signal. onAppear covers cold starts and tab switches; onChange covers
    /// taps while this tab is already showing.
    private func consumePendingAllAccountsNavigation() {
        guard notificationRouter.pendingAllAccountsNavigation else { return }
        path = NavigationPath([AllAccountsRoute()])
        notificationRouter.pendingAllAccountsNavigation = false
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
            Text(budgetStore.displayBalance(account.balance))
                .foregroundColor(account.balance > 0 ? .green : (account.balance < 0 ? .red : .primary))
        }
    }
}

#Preview {
    AccountsListView()
        .environmentObject(BudgetStore.previewInstance())
}
