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
    // A singleton reference, not a view-owned object — @ObservedObject is the
    // semantically correct wrapper here. @StateObject would imply this view
    // creates/owns the router's lifecycle, which it doesn't; functionally
    // both work identically for a `.shared` instance, since the underlying
    // object never changes regardless of how the view struct re-inits.
    @ObservedObject private var notificationRouter = NotificationRouter.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isWideLayout) private var isWideLayout
    @State private var path = NavigationPath()
    @State private var showingAddAccount = false
    /// Split layout only. Starts on All Accounts so the detail column has
    /// something in it at launch instead of an empty pane.
    @State private var selection: AccountSelection? = .allAccounts

    /// Independent expand/collapse state per section.
    @State private var isOnBudgetExpanded = true
    @State private var isOffBudgetExpanded = true
    @State private var isClosedExpanded = true

    /// Two real columns, or tap-and-push? Width, not just size class: in a
    /// window too narrow for a second column the split view hides the sidebar
    /// behind a drawer that opens over the content and under the floating tab
    /// bar, which is worse than the phone's push navigation.
    private var usesSplitLayout: Bool {
        horizontalSizeClass == .regular && isWideLayout
    }

    var totalBalance: Int {
        budgetStore.accounts.sumBalance
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

    var onBudgetTotal: Int { onBudgetAccounts.sumBalance }
    var offBudgetTotal: Int { offBudgetAccounts.sumBalance }
    var closedTotal: Int { closedAccounts.sumBalance }

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
                            Section {
                                if isOnBudgetExpanded {
                                    ForEach(onBudgetAccounts) { account in
                                        NavigationLink(value: account) {
                                            AccountRow(account: account)
                                        }
                                    }
                                }
                            } header: {
                                AccountSectionHeader(
                                    title: "On Budget",
                                    total: onBudgetTotal,
                                    isExpanded: $isOnBudgetExpanded
                                )
                            }
                        }
                        if !offBudgetAccounts.isEmpty {
                            Section {
                                if isOffBudgetExpanded {
                                    ForEach(offBudgetAccounts) { account in
                                        NavigationLink(value: account) {
                                            AccountRow(account: account)
                                        }
                                    }
                                }
                            } header: {
                                AccountSectionHeader(
                                    title: "Off Budget",
                                    total: offBudgetTotal,
                                    isExpanded: $isOffBudgetExpanded
                                )
                            }
                        }
                        if !closedAccounts.isEmpty {
                            Section {
                                if isClosedExpanded {
                                    ForEach(closedAccounts) { account in
                                        NavigationLink(value: account) {
                                            AccountRow(account: account)
                                        }
                                    }
                                }
                            } header: {
                                AccountSectionHeader(
                                    title: "Closed Accounts",
                                    total: closedTotal,
                                    isExpanded: $isClosedExpanded
                                )
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
                            Section {
                                if isOnBudgetExpanded {
                                    ForEach(onBudgetAccounts) { account in
                                        AccountRow(account: account)
                                            .tag(AccountSelection.account(account.id))
                                    }
                                }
                            } header: {
                                AccountSectionHeader(
                                    title: "On Budget",
                                    total: onBudgetTotal,
                                    isExpanded: $isOnBudgetExpanded
                                )
                            }
                        }
                        if !offBudgetAccounts.isEmpty {
                            Section {
                                if isOffBudgetExpanded {
                                    ForEach(offBudgetAccounts) { account in
                                        AccountRow(account: account)
                                            .tag(AccountSelection.account(account.id))
                                    }
                                }
                            } header: {
                                AccountSectionHeader(
                                    title: "Off Budget",
                                    total: offBudgetTotal,
                                    isExpanded: $isOffBudgetExpanded
                                )
                            }
                        }
                        if !closedAccounts.isEmpty {
                            Section {
                                if isClosedExpanded {
                                    ForEach(closedAccounts) { account in
                                        AccountRow(account: account)
                                            .tag(AccountSelection.account(account.id))
                                    }
                                }
                            } header: {
                                AccountSectionHeader(
                                    title: "Closed Accounts",
                                    total: closedTotal,
                                    isExpanded: $isClosedExpanded
                                )
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
                .foregroundStyle(balanceColor(for: totalBalance))
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
    /// status, notification routing, pull-to-refresh, loading overlay.
    /// Shared so the two layouts can't drift apart.
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

/// Green over positive, red over negative, primary at exactly zero — shared
/// by every balance-displaying view in this file so the three don't drift.
private func balanceColor(for balance: Int) -> Color {
    if balance > 0 { return .green }
    if balance < 0 { return .red }
    return .primary
}

private extension Array where Element == Account {
    /// Sum of every account's balance in the array — used for the "All
    /// Accounts" total and each section's subtotal alike, so the reduction
    /// itself only lives in one place.
    var sumBalance: Int {
        reduce(0) { $0 + $1.balance }
    }
}

/// Header used for the On Budget, Off Budget, and Closed Accounts sections.
/// The section name sits on the left, the total is right-aligned with extra
/// trailing padding to separate it from the screen edge, and tapping
/// anywhere on the header expands/collapses that section.
private enum AccountSectionHeaderMetrics {
    /// Extra breathing room between the total and the trailing edge, beyond
    /// the list's own content margin.
    static let totalTrailingPadding: CGFloat = 24
}

struct AccountSectionHeader: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let title: String
    let total: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .frame(width: 12)
                    // Decorative: the expanded/collapsed state is already
                    // conveyed through the accessibility hint below, so this
                    // icon would otherwise just add noise before the title.
                    .accessibilityHidden(true)
                Text(title)
                Spacer()
                Text(budgetStore.displayBalance(total))
                    .fontWeight(.regular)
                    .foregroundStyle(balanceColor(for: total))
                    .padding(.trailing, AccountSectionHeaderMetrics.totalTrailingPadding)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(title), \(budgetStore.displayBalance(total))")
        // Hints describe the result of the action, not the gesture itself —
        // VoiceOver already announces this as double-tap-activatable.
        .accessibilityHint(isExpanded ? "Collapses this section" : "Expands this section")
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
                .foregroundStyle(balanceColor(for: account.balance))
        }
    }
}

#Preview {
    AccountsListView()
        .environmentObject(BudgetStore.previewInstance())
}
