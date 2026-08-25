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

/// A month's totals carried together with the month they were fetched for.
/// The two travel as one so the summary card can't caption August's figures
/// with September, which is exactly what happens when the calendar rolls over
/// under a view that reads "now" afresh on every render.
struct AccountsMonthTotals: Equatable {
    let month: String
    let totals: BudgetDatabase.AccountsMonthSummary
}

struct AccountsListView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @StateObject private var notificationRouter = NotificationRouter.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isWideLayout) private var isWideLayout
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()
    @State private var showingAddAccount = false
    @State private var showingPendingImports = false
    @StateObject private var pendingImportStore = PendingImportStore.shared
    /// Split layout only. Starts on All Accounts so the detail column has
    /// something in it at launch instead of an empty pane.
    @State private var selection: AccountSelection? = .allAccounts
    /// This month's money in and out, for the summary card. nil until the
    /// first fetch lands.
    @State private var monthSummary: AccountsMonthTotals?

    /// Independent expand/collapse state per section, persisted so a
    /// collapsed section stays collapsed across launches — same contract as
    /// the budget tab's collapsedBudgetGroups.
    @AppStorage("accountsOnBudgetExpanded") private var isOnBudgetExpanded = true
    @AppStorage("accountsOffBudgetExpanded") private var isOffBudgetExpanded = true
    @AppStorage("accountsClosedExpanded") private var isClosedExpanded = true

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
        budgetStore.visibleClosedAccounts
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
                                    isExpanded: $isOnBudgetExpanded,
                                    totalTrailingPadding: 0
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
                                    isExpanded: $isOffBudgetExpanded,
                                    totalTrailingPadding: 0
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
                                    isExpanded: $isClosedExpanded,
                                    totalTrailingPadding: 0
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
        AccountsSummaryCard(totalBalance: totalBalance, monthTotals: monthSummary)
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
                description: Text("You're connected. Choose a budget in More → Connection & Data to load it here.")
            )
        } else {
            ContentUnavailableView(
                "No Budget Loaded",
                systemImage: "dollarsign.circle",
                description: Text("Go to More → Connection & Data to connect to your Actual Budget server")
            )
        }
    }

    /// Everything both layouts hang off their account list: title, sync
    /// status, notification routing, pull-to-refresh, loading overlay.
    /// Shared so the two layouts can't drift apart.
    private func withChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Group(content: content)
            // Both layouts' section state lives in @AppStorage, and a write to
            // that lands outside any withAnimation transaction — so the rows
            // have to be animated from here, off the stored flags.
            .animation(
                AppAnimation.disclosure,
                value: [isOnBudgetExpanded, isOffBudgetExpanded, isClosedExpanded]
            )
            .contentMargins(.horizontal, 6, for: .scrollContent)
//            .navigationTitle("Accounts")
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
                    Menu {
                        if !budgetStore.bankSyncAccounts.isEmpty {
                            Button {
                                Task { await budgetStore.runBankSync() }
                            } label: {
                                Label("Sync Bank Accounts", systemImage: "building.columns")
                            }
                            .disabled(budgetStore.isBankSyncing)
                        }
                        Toggle(isOn: $budgetStore.hideClosedAccounts) {
                            Label("Hide Closed", systemImage: "archivebox")
                        }
                        .accessibilityLabel("Hide Closed Accounts")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Accounts options")
                    .accessibilityHint("Account list display options")
                }
                if pendingImportStore.count > 0 {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingPendingImports = true
                        } label: {
                            Image(systemName: "tray.and.arrow.down")
                                .overlay(alignment: .topTrailing) {
                                    Text("\(pendingImportStore.count)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(3)
                                        .background(.red, in: Circle())
                                        .offset(x: 6, y: -6)
                                }
                        }
                        .accessibilityLabel("Pending imports")
                        .accessibilityValue("\(pendingImportStore.count) pending")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    SyncStatusView(state: budgetStore.syncState)
                }
            }
            .sheet(isPresented: $showingAddAccount) {
                AddAccountView()
                    .environmentObject(budgetStore)
            }
            // Attached here, not on the menu item that starts the sync: the
            // menu is long gone by the time the download finishes, and this
            // stack's pushed account views sit above this alert anyway.
            .alert("Bank Sync", isPresented: bankSyncAlertBinding) {
                Button("OK", role: .cancel) { budgetStore.bankSyncSummary = nil }
            } message: {
                Text(budgetStore.bankSyncSummary ?? "")
            }
            .sheet(isPresented: $showingPendingImports) {
                PendingImportsView()
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
            // Keyed to dataVersion so the summary's month totals follow every
            // edit and sync, like the account balances beneath them.
            .task(id: budgetStore.dataVersion) { await loadMonthSummary() }
            // Nothing above re-runs when only the date changes, so a phone
            // left on this tab overnight would keep showing last month's
            // totals. Foregrounding is when that becomes visible, and the
            // tab's own .task covers coming back from another tab.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await loadMonthSummary() }
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
    
    private var bankSyncAlertBinding: Binding<Bool> {
        Binding(
            get: { budgetStore.bankSyncSummary != nil },
            set: { if !$0 { budgetStore.bankSyncSummary = nil } }
        )
    }

    private func loadMonthSummary() async {
        let month = BudgetView.currentMonthString()
        guard let totals = await budgetStore.fetchAccountsMonthSummary(month: month) else { return }
        monthSummary = AccountsMonthTotals(month: month, totals: totals)
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

/// The list's lead row: the all-accounts balance over this month's income,
/// spending, and the difference — the same figures, on the same budgeted
/// scope, that the budget tab opens with (GH #256). It's still the row that
/// pushes the All Accounts transaction list, so the figures lead to the
/// transactions behind them.
struct AccountsSummaryCard: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let totalBalance: Int
    /// nil until the month's totals land; the stats read "—" until then
    /// rather than flashing zeroes that a moment later turn into real money.
    /// The month rides along with them so the caption always names the month
    /// the figures were fetched for.
    let monthTotals: AccountsMonthTotals?

    private var summary: BudgetDatabase.AccountsMonthSummary? { monthTotals?.totals }

    var body: some View {
        let balance = budgetStore.displayBalance(totalBalance)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("All Accounts")
                    .font(.headline)
                Spacer()
                Text(balance)
                    .font(.headline)
                    .foregroundStyle(balanceColor(for: totalBalance))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .animatedAmount(balance)
            }
            Divider()
            // Falls back to today's month only while the figures are still
            // dashes — there's nothing yet for the caption to disagree with.
            Text(MonthPicker.title(for: monthTotals?.month ?? BudgetView.currentMonthString()))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                SummaryStat(label: "Income", value: amount(summary?.incomeCents))
                Spacer(minLength: 4)
                SummaryStat(
                    label: "Expenses",
                    value: amount(summary?.expenseCents),
                    alignment: .center
                )
                Spacer(minLength: 4)
                SummaryStat(
                    label: "Net",
                    value: amount(summary?.netCents),
                    // Same three-way treatment as the balances, and neutral
                    // while there's only a placeholder to color.
                    valueColor: summary.map { balanceColor(for: $0.netCents) } ?? .primary,
                    alignment: .trailing
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func amount(_ cents: Int?) -> String {
        guard let cents else { return "—" }
        return budgetStore.displayBalance(cents)
    }
}

/// Header used for the On Budget, Off Budget, and Closed Accounts sections.
/// The section name sits on the left, the total is right-aligned, and tapping
/// anywhere on the header expands/collapses that section.
struct AccountSectionHeader: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let title: String
    let total: Int
    @Binding var isExpanded: Bool
    /// Extra trailing inset lining the total up with row balances that sit
    /// left of a NavigationLink disclosure chevron. The split layout's rows
    /// carry no chevron, so it passes zero to keep its totals flush too.
    var totalTrailingPadding: CGFloat = 24

    var body: some View {
        let totalText = budgetStore.displayBalance(total)
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                DisclosureChevron(isExpanded: isExpanded)
                                    .frame(width: 12)
                Text(title)
                Spacer()
                Text(totalText)
                    .fontWeight(.regular)
                    .foregroundStyle(balanceColor(for: total))
                    .animatedAmount(totalText)
                    // Grouped-list headers uppercase their content; fine for
                    // the title (string headers always rendered that way) but
                    // it would mangle alphabetic currency symbols ("kr"→"KR").
                    .textCase(nil)
                    // One line always: a narrow sidebar wraps "USD 48,800.00"
                    // onto two lines rather than shrinking it.
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.trailing, totalTrailingPadding)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        // State lives in the label, not the hint: hints are read last and can
        // be disabled outright, and a collapsed section is otherwise
        // indistinguishable from an empty one. Same convention as the budget
        // tab's group headers ("Essentials, collapsed").
        .accessibilityLabel("\(title), \(expandedState), \(totalText)")
        .accessibilityIdentifier("\(title), \(expandedState)")
        // Hints describe the result of the action, not the gesture itself —
        // VoiceOver already announces this as double-tap-activatable.
        .accessibilityHint(isExpanded ? "Collapses this section" : "Expands this section")
    }

    private var expandedState: String {
        isExpanded ? "expanded" : "collapsed"
    }
}

struct AccountRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let account: Account

    var body: some View {
        let balance = budgetStore.displayBalance(account.balance)
        HStack {
            Text(account.name)
                .font(.body)
            Spacer()
            Text(balance)
                .foregroundStyle(balanceColor(for: account.balance))
                .animatedAmount(balance)
        }
    }
}

#Preview {
    AccountsListView()
        .environmentObject(BudgetStore.previewInstance())
}
