import SwiftUI

/// Value-based route for the All Accounts transaction list, so the
/// notification tap can programmatically reset the stack onto it.
struct AllAccountsRoute: Hashable {}

/// Which detail the iPad's split layout is showing. Accounts are held by id,
/// not by value: the `Account` struct changes on every sync (balances move),
/// and a stored value would stop matching its row the moment it did.
private enum AccountSelection: Hashable {
    case allAccounts
    case account(String)
}

struct AccountsListView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @StateObject private var notificationRouter = NotificationRouter.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isWideLayout) private var isWideLayout
    @State private var path = NavigationPath()
    @State private var showingAddAccount = false
    /// Split layout only. Starts on All Accounts so the detail column has
    /// something in it at launch instead of an empty pane.
    @State private var selection: AccountSelection? = .allAccounts

    /// Two real columns, or tap-and-push? Width, not just size class: in a
    /// window too narrow for a second column the split view hides the sidebar
    /// behind a drawer that opens over the content and under the floating tab
    /// bar, which is worse than the phone's push navigation.
    private var usesSplitLayout: Bool {
        horizontalSizeClass == .regular && isWideLayout
    }

    var totalBalance: Int {
        budgetStore.accounts.reduce(0) { $0 + $1.balance }
    }

    var onBudgetAccounts: [Account] {
        budgetStore.accounts.filter { !$0.offBudget && !$0.closed }
    }

    var offBudgetAccounts: [Account] {
        budgetStore.accounts.filter { $0.offBudget && !$0.closed }
    }

    var closedAccounts: [Account] {
        budgetStore.accounts.filter { $0.closed }
    }

    var body: some View {
        Group {
            // A wide iPad window puts the account list beside its transactions
            // instead of pushing to them.
            if usesSplitLayout {
                splitLayout
            } else {
                stackLayout
            }
        }
        .initialSyncBanner()
    }

    /// The phone layout: tap an account, push its transactions.
    private var stackLayout: some View {
        NavigationStack(path: $path) {
            withChrome {
                if hasNoAccounts {
                    emptyState
                } else {
                    List {
                        Section {
                            NavigationLink(value: AllAccountsRoute()) {
                                allAccountsRow
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

                        if !closedAccounts.isEmpty {
                            Section("Closed Accounts") {
                                ForEach(closedAccounts) { account in
                                    NavigationLink(value: account) {
                                        AccountRow(account: account)
                                    }
                                }
                            }
                        }
                    }
                    // Capped like the transactions this pushes to, so a
                    // narrow-iPad account list doesn't stretch a row's balance
                    // an inch away from its name. Only here: the split
                    // layout's copy is a sidebar and sizes itself.
                    .readableWidth()
                }
            }
            .navigationDestination(for: Account.self) { account in
                AccountDetailView(account: account)
            }
            .navigationDestination(for: AllAccountsRoute.self) { _ in
                TransactionsListView()
            }
        }
    }

    /// The iPad layout: the same list as a sidebar, transactions alongside.
    private var splitLayout: some View {
        NavigationSplitView {
            withChrome {
                if hasNoAccounts {
                    emptyState
                } else {
                    List(selection: $selection) {
                        Section {
                            allAccountsRow
                                .tag(AccountSelection.allAccounts)
                        }

                        if !onBudgetAccounts.isEmpty {
                            Section("On Budget") {
                                ForEach(onBudgetAccounts) { account in
                                    AccountRow(account: account)
                                        .tag(AccountSelection.account(account.id))
                                }
                            }
                        }

                        if !offBudgetAccounts.isEmpty {
                            Section("Off Budget") {
                                ForEach(offBudgetAccounts) { account in
                                    AccountRow(account: account)
                                        .tag(AccountSelection.account(account.id))
                                }
                            }
                        }

                        if !closedAccounts.isEmpty {
                            Section("Closed Accounts") {
                                ForEach(closedAccounts) { account in
                                    AccountRow(account: account)
                                        .tag(AccountSelection.account(account.id))
                                }
                            }
                        }
                    }
                }
            }
        } detail: {
            NavigationStack {
                switch selection {
                case .account(let id):
                    // Resolved fresh from the store so the detail follows
                    // balance changes, and degrades gracefully if the account
                    // is closed or removed out from under the selection.
                    if let account = budgetStore.accounts.first(where: { $0.id == id }) {
                        AccountDetailView(account: account)
                    } else {
                        ContentUnavailableView(
                            "Account Unavailable",
                            systemImage: "banknote",
                            description: Text("Pick another account from the list.")
                        )
                    }
                case .allAccounts:
                    TransactionsListView()
                case nil:
                    ContentUnavailableView(
                        "No Account Selected",
                        systemImage: "banknote",
                        description: Text("Pick an account from the list.")
                    )
                }
            }
        }
    }

    private var hasNoAccounts: Bool {
        budgetStore.accounts.isEmpty && !budgetStore.isLoading
    }

    private var allAccountsRow: some View {
        HStack {
            Text("All Accounts")
                .font(.headline)
            Spacer()
            Text(budgetStore.displayBalance(totalBalance))
                .font(.headline)
                .foregroundColor(totalBalance > 0 ? .green : (totalBalance < 0 ? .red : .primary))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if budgetStore.currentBudgetId != nil {
            // A budget is loaded, it just has no accounts (yet) —
            // "go connect a server" would be wrong advice here (GH #122).
            ContentUnavailableView(
                "No Accounts",
                systemImage: "dollarsign.circle",
                description: Text("This budget doesn't have any accounts yet. Create one in Actual Budget, then sync.")
            )
        } else if budgetStore.isConnected {
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
    }

    /// Everything both layouts hang off their account list: title, sync
    /// status, notification routing, pull-to-refresh, loading overlay. Shared
    /// so the two layouts can't drift apart.
    private func withChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Group(content: content)
            .contentMargins(.horizontal, 6, for: .scrollContent)
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddAccount = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Account")
                }
                ToolbarItem(placement: .primaryAction) {
                    SyncStatusView(state: budgetStore.syncState)
                }
            }
            .sheet(isPresented: $showingAddAccount) {
                AddAccountView()
                    .environmentObject(budgetStore)
            }
            .onAppear {
                consumePendingAllAccountsNavigation()
                consumePendingAccountNavigation()
            }
            .onChange(of: notificationRouter.pendingAllAccountsNavigation) { _, pending in
                if pending { consumePendingAllAccountsNavigation() }
            }
            .onChange(of: notificationRouter.pendingAccountNavigation) { _, accountId in
                if accountId != nil { consumePendingAccountNavigation() }
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

    /// Tapping a success notification lands here: jump the stack straight to
    /// All Accounts (replacing anything the user had pushed) and clear the
    /// signal. onAppear covers cold starts and tab switches; onChange covers
    /// taps while this tab is already showing.
    private func consumePendingAllAccountsNavigation() {
        guard notificationRouter.pendingAllAccountsNavigation else { return }
        if usesSplitLayout {
            selection = .allAccounts
        } else {
            path = NavigationPath([AllAccountsRoute()])
        }
        notificationRouter.pendingAllAccountsNavigation = false
    }

    /// A save in the tab-hosted add flow lands here: jump the stack straight
    /// to the saved transaction's account (replacing anything the user had
    /// pushed) and clear the signal. onChange covers the usual case; onAppear
    /// covers a save before this tab was ever created, when the signal is
    /// already pending as the view first appears.
    private func consumePendingAccountNavigation() {
        guard let accountId = notificationRouter.pendingAccountNavigation else { return }
        notificationRouter.pendingAccountNavigation = nil
        guard let account = budgetStore.accounts.first(where: { $0.id == accountId }) else { return }
        if usesSplitLayout {
            selection = .account(account.id)
        } else {
            path = NavigationPath([account])
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
            Text(budgetStore.displayBalance(account.balance))
                .foregroundColor(account.balance > 0 ? .green : (account.balance < 0 ? .red : .primary))
        }
    }
}

#Preview {
    AccountsListView()
        .environmentObject(BudgetStore.previewInstance())
}
