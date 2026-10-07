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

/// What the month summary is fetched from, so one `.task(id:)` reloads it
/// when either changes.
private struct MonthSummaryInputs: Equatable {
    let dataVersion: Int
    let excludedFromSpent: Set<String>
}

struct AccountsListView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @StateObject private var notificationRouter = NotificationRouter.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isWideLayout) private var isWideLayout
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()
    @State private var showingAddAccount = false
    @State private var showingCreditCards = false
    @State private var showingLoans = false
    @State private var showingDeposits = false
    @State private var showingBills = false
    @State private var showingPendingImports = false
    @StateObject private var pendingImportStore = PendingImportStore.shared
    /// Split layout only. Starts on All Accounts so the detail column has
    /// something in it at launch instead of an empty pane.
    @State private var selection: AccountSelection? = .allAccounts
    /// This month's money in and out, for the summary card. nil until the
    /// first fetch lands.
    @State private var monthSummary: AccountsMonthTotals?
    @State private var accountSearchText = ""
    @State private var isAccountSearchActive = false
    @FocusState private var isAccountSearchFocused: Bool

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

    /// Section totals always cover the whole section, search or not, so a
    /// header's number never silently changes meaning while filtering.
    var onBudgetTotal: Int {
        onBudgetAccounts.sumBalance
    }

    var offBudgetTotal: Int {
        offBudgetAccounts.sumBalance
    }

    var closedTotal: Int {
        closedAccounts.sumBalance
    }

    private var filteredOnBudgetAccounts: [Account] {
        Self.filterAccounts(onBudgetAccounts, matching: accountSearchText)
    }

    private var filteredOffBudgetAccounts: [Account] {
        Self.filterAccounts(offBudgetAccounts, matching: accountSearchText)
    }

    private var filteredClosedAccounts: [Account] {
        Self.filterAccounts(closedAccounts, matching: accountSearchText)
    }

    private var isSearchingAccounts: Bool {
        !accountSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasNoSearchResults: Bool {
        isSearchingAccounts
            && filteredOnBudgetAccounts.isEmpty
            && filteredOffBudgetAccounts.isEmpty
            && filteredClosedAccounts.isEmpty
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
        // Outside both navigation containers, not on the list root: a pushed
        // account screen (where Sync from Bank lives) covers the root, and an
        // alert there waits until the user backs out to present.
        .alert("Bank Sync", isPresented: bankSyncAlertBinding) {
            Button(String(localized: "common.ok"), role: .cancel) { budgetStore.bankSyncSummary = nil }
        } message: {
            Text(budgetStore.bankSyncSummary ?? "")
        }
    }

    /// The phone layout: tap an account, push its transactions.
    private var stackLayout: some View {
        NavigationStack(path: $path) {
            withChrome {
                if hasNoAccounts {
                    emptyState
                } else {
                    List {
                        if !isSearchingAccounts {
                            Section {
                                NavigationLink(value: AllAccountsRoute()) {
                                    allAccountsRow
                                }
                            }
                        }
                        if !filteredOnBudgetAccounts.isEmpty {
                            Section {
                                if isOnBudgetExpanded || isSearchingAccounts {
                                    ForEach(filteredOnBudgetAccounts) { account in
                                        NavigationLink(value: account) {
                                            AccountRow(account: account)
                                        }
                                    }
                                }
                            } header: {
                                AccountSectionHeader(
                                    identifier: "on-budget",
                                    title: String(localized: "On Budget"),
                                    total: onBudgetTotal,
                                    isExpanded: isSearchingAccounts ? .constant(true) : $isOnBudgetExpanded,
                                    allowsCollapse: !isSearchingAccounts
                                )
                            }
                        }
                        if !filteredOffBudgetAccounts.isEmpty {
                            Section {
                                if isOffBudgetExpanded || isSearchingAccounts {
                                    ForEach(filteredOffBudgetAccounts) { account in
                                        NavigationLink(value: account) {
                                            AccountRow(account: account)
                                        }
                                    }
                                }
                            } header: {
                                AccountSectionHeader(
                                    identifier: "off-budget",
                                    title: String(localized: "Off Budget"),
                                    total: offBudgetTotal,
                                    isExpanded: isSearchingAccounts ? .constant(true) : $isOffBudgetExpanded,
                                    allowsCollapse: !isSearchingAccounts
                                )
                            }
                        }
                        if !filteredClosedAccounts.isEmpty {
                            Section {
                                if isClosedExpanded || isSearchingAccounts {
                                    ForEach(filteredClosedAccounts) { account in
                                        NavigationLink(value: account) {
                                            AccountRow(account: account)
                                        }
                                    }
                                }
                            } header: {
                                AccountSectionHeader(
                                    identifier: "closed",
                                    title: String(localized: "Closed Accounts"),
                                    total: closedTotal,
                                    isExpanded: isSearchingAccounts ? .constant(true) : $isClosedExpanded,
                                    allowsCollapse: !isSearchingAccounts
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
                AccountTransactionsScreen(account: account)
            }
            .navigationDestination(for: AllAccountsRoute.self) { _ in
                AccountTransactionsScreen()
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
                        if !isSearchingAccounts {
                            Section {
                                allAccountsRow
                                    .tag(AccountSelection.allAccounts)
                            }
                        }
                        if !filteredOnBudgetAccounts.isEmpty {
                            Section {
                                if isOnBudgetExpanded || isSearchingAccounts {
                                    ForEach(filteredOnBudgetAccounts) { account in
                                        AccountRow(account: account)
                                            .tag(AccountSelection.account(account.id))
                                    }
                                }
                            } header: {
                                AccountSectionHeader(
                                    identifier: "on-budget",
                                    title: String(localized: "On Budget"),
                                    total: onBudgetTotal,
                                    isExpanded: isSearchingAccounts ? .constant(true) : $isOnBudgetExpanded,
                                    allowsCollapse: !isSearchingAccounts,
                                    totalTrailingPadding: 0
                                )
                            }
                        }
                        if !filteredOffBudgetAccounts.isEmpty {
                            Section {
                                if isOffBudgetExpanded || isSearchingAccounts {
                                    ForEach(filteredOffBudgetAccounts) { account in
                                        AccountRow(account: account)
                                            .tag(AccountSelection.account(account.id))
                                    }
                                }
                            } header: {
                                AccountSectionHeader(
                                    identifier: "off-budget",
                                    title: String(localized: "Off Budget"),
                                    total: offBudgetTotal,
                                    isExpanded: isSearchingAccounts ? .constant(true) : $isOffBudgetExpanded,
                                    allowsCollapse: !isSearchingAccounts,
                                    totalTrailingPadding: 0
                                )
                            }
                        }
                        if !filteredClosedAccounts.isEmpty {
                            Section {
                                if isClosedExpanded || isSearchingAccounts {
                                    ForEach(filteredClosedAccounts) { account in
                                        AccountRow(account: account)
                                            .tag(AccountSelection.account(account.id))
                                    }
                                }
                            } header: {
                                AccountSectionHeader(
                                    identifier: "closed",
                                    title: String(localized: "Closed Accounts"),
                                    total: closedTotal,
                                    isExpanded: isSearchingAccounts ? .constant(true) : $isClosedExpanded,
                                    allowsCollapse: !isSearchingAccounts,
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
                        AccountTransactionsScreen(account: account)
                    } else {
                        ContentUnavailableView(
                            "Account Unavailable",
                            systemImage: "building.columns",
                            description: Text("Pick another account from the list.")
                        )
                    }
                case .allAccounts:
                    AccountTransactionsScreen()
                case nil:
                    ContentUnavailableView(
                        "No Account Selected",
                        systemImage: "building.columns",
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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("accounts.topBox")
    }

    @ViewBuilder
    private var emptyState: some View {
        if budgetStore.currentBudgetId != nil {
            // A budget is loaded, it just has no accounts (yet) —
            // "go connect a server" would be wrong advice here (GH #122).
            ContentUnavailableView(
                String(localized: "No Accounts"),
                systemImage: "dollarsign.circle",
                description: Text(String(localized: "This budget doesn't have any accounts yet. Create one in Actual Budget, then sync."))
            )
        } else if budgetStore.isConnected {
            ContentUnavailableView(
                String(localized: "Select a Budget"),
                systemImage: "dollarsign.circle",
                description: Text(String(localized: "You're connected. Choose a budget in More → Connection & Data to load it here."))
            )
        } else {
            ContentUnavailableView(
                String(localized: "No Budget Loaded"),
                systemImage: "dollarsign.circle",
                description: Text(String(localized: "Go to More → Connection & Data to connect to your Actual Budget server"))
            )
        }
    }

    /// Everything both layouts hang off their account list: title, notification
    /// routing, pull-to-refresh, loading overlay, search.
    /// Shared so the two layouts can't drift apart.
    private func withChrome(@ViewBuilder _ content: () -> some View) -> some View {
        Group(content: content)
            // Both layouts' section state lives in @AppStorage, and a write to
            // that lands outside any withAnimation transaction — so the rows
            // have to be animated from here, off the stored flags.
            .animation(
                AppAnimation.disclosure,
                value: [isOnBudgetExpanded, isOffBudgetExpanded, isClosedExpanded]
            )
            .contentMargins(
                .horizontal,
                TopBoxLayout.horizontalContentMargin,
                for: .scrollContent
            )
            .contentMargins(
                .top,
                TopBoxLayout.verticalContentMargin,
                for: .scrollContent
            )
            .overlay {
                if hasNoSearchResults {
                    ContentUnavailableView.search(text: accountSearchText)
                }
            }
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $accountSearchText,
                isPresented: $isAccountSearchActive,
                placement: .navigationBarDrawer,
                prompt: String(localized: "Search Accounts")
            )
            .searchFocused($isAccountSearchFocused)
            .onChange(of: isAccountSearchActive) { _, isActive in
                if !isActive {
                    accountSearchText = ""
                }
            }
            .toolbar {
                if !hasNoAccounts, !isAccountSearchActive {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isAccountSearchActive = true
                            isAccountSearchFocused = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel(String(localized: "Search Accounts"))
                        .accessibilityIdentifier("accounts.search")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddAccount = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(String(localized: "accounts.add.title"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if !budgetStore.bankSyncAccounts.isEmpty {
                            Button {
                                Task { await budgetStore.runBankSync() }
                            } label: {
                                Label(String(localized: "Sync Bank Accounts"), systemImage: "building.columns")
                            }
                            .disabled(budgetStore.isBankSyncing)
                        }
                        Button {
                            showingCreditCards = true
                        } label: {
                            Label(String(localized: "Credit Cards"), systemImage: "creditcard")
                        }
                        Button {
                            showingLoans = true
                        } label: {
                            Label(String(localized: "Loans"), systemImage: "banknote")
                        }
                        Button {
                            showingDeposits = true
                        } label: {
                            Label(String(localized: "Deposits"), systemImage: "chart.line.uptrend.xyaxis")
                        }
                        Button {
                            showingBills = true
                        } label: {
                            Label("Bills & Calendar", systemImage: "calendar")
                        }
                        Divider()
                        Toggle(isOn: $budgetStore.hideClosedAccounts) {
                            Label(String(localized: "Hide Closed"), systemImage: "archivebox")
                        }
                        .accessibilityLabel(String(localized: "Hide Closed Accounts"))
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(String(localized: "Accounts options"))
                    .accessibilityHint(String(localized: "Account list display options"))
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
                        .accessibilityValue(String(localized: "\(pendingImportStore.count) pending"))
                    }
                }
            }
            .sheet(isPresented: $showingAddAccount) {
                AddAccountView()
                    .environmentObject(budgetStore)
            }
            .sheet(isPresented: $showingPendingImports) {
                PendingImportsView()
                    .environmentObject(budgetStore)
            }
            .sheet(isPresented: $showingCreditCards) {
                NavigationStack {
                    CreditCardsSettingsView()
                        .environmentObject(budgetStore)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(String(localized: "common.done")) { showingCreditCards = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showingLoans) {
                NavigationStack {
                    LoansSettingsView()
                        .environmentObject(budgetStore)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(String(localized: "common.done")) { showingLoans = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showingDeposits) {
                NavigationStack {
                    DepositsSettingsView()
                        .environmentObject(budgetStore)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(String(localized: "common.done")) { showingDeposits = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showingBills) {
                NavigationStack {
                    BillsCalendarView()
                        .environmentObject(budgetStore)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingBills = false }
                            }
                        }
                }
            }
            .onAppear {
                consumePendingAllAccountsNavigation()
                consumePendingAccountNavigation()
            }
            .onChange(of: notificationRouter.pendingAllAccountsNavigation) { _, pending in
                if pending {
                    consumePendingAllAccountsNavigation()
                }
            }
            .onChange(of: notificationRouter.pendingAccountNavigation) { _, accountId in
                if accountId != nil {
                    consumePendingAccountNavigation()
                }
            }
            // Keyed to dataVersion so the summary's month totals follow every
            // edit and sync, like the account balances beneath them, and to
            // the Spent exclusions, which change the totals without an edit.
            .task(id: MonthSummaryInputs(
                dataVersion: budgetStore.dataVersion,
                excludedFromSpent: budgetStore.excludedFromSpentCategoryIds
            )) { await loadMonthSummary() }
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

    nonisolated static func filterAccounts(_ accounts: [Account], matching query: String) -> [Account] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return accounts }
        return accounts.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var bankSyncAlertBinding: Binding<Bool> {
        Binding(
            get: { budgetStore.bankSyncSummary != nil },
            set: {
                if !$0 {
                    budgetStore.bankSyncSummary = nil
                }
            }
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

/// One owner for the transaction-screen chrome used by both All Accounts and
/// individual accounts. Keeping the status strip outside the two content
/// variants prevents navigation from recycling its rendered scroll content.
private struct AccountTransactionsScreen: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    var account: Account?

    var body: some View {
        Group {
            if let account {
                AccountDetailView(account: account)
            } else {
                TransactionsListView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if budgetStore.showTransactionStatusFilters {
                TransactionFilterStrip(
                    selection: $budgetStore.transactionStatusFilter,
                    filters: account?.offBudget == true
                        ? TransactionStatusFilter.allCases.filter { $0 != .uncategorized }
                        : TransactionStatusFilter.allCases
                )
            }
        }
        .task(id: account?.id) {
            if account?.offBudget == true,
               budgetStore.transactionStatusFilter == .uncategorized {
                budgetStore.transactionStatusFilter = .all
            }
        }
    }
}

/// Green over positive, red over negative, primary at exactly zero — shared
/// by every balance-displaying view so the copies don't drift.
func balanceColor(for balance: Int) -> Color {
    if balance > 0 {
        return .green
    }
    if balance < 0 {
        return .red
    }
    return .primary
}

private extension [Account] {
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

    private var summary: BudgetDatabase.AccountsMonthSummary? {
        monthTotals?.totals
    }

    var body: some View {
        let balance = budgetStore.displayBalance(totalBalance)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "All Accounts"))
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
                    label: "Spent",
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
    let identifier: String
    let title: String
    let total: Int
    @Binding var isExpanded: Bool
    var allowsCollapse = true
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
        .disabled(!allowsCollapse)
        .accessibilityAddTraits(.isHeader)
        // State lives in the label, not the hint: hints are read last and can
        // be disabled outright, and a collapsed section is otherwise
        // indistinguishable from an empty one. Same convention as the budget
        // tab's group headers ("Essentials, collapsed").
        .accessibilityLabel(String(format: String(localized: "accounts.group.accessibility"), title, expandedState, totalText))
        .accessibilityIdentifier("account.group.\(identifier)")
        // Hints describe the result of the action, not the gesture itself —
        // VoiceOver already announces this as double-tap-activatable.
        .accessibilityHint(allowsCollapse
            ? (isExpanded
                ? String(localized: "Collapses this section")
                : String(localized: "Expands this section"))
            : "")
    }

    private var expandedState: String {
        isExpanded ? String(localized: "expanded") : String(localized: "collapsed")
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
