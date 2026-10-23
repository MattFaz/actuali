import SwiftUI

/// Value-based routes for the phone stack. Typed rather than a
/// `NavigationPath` so a notification tap can reset the stack onto All
/// Accounts, and a save can tell when All Accounts is already showing.
private enum AccountsRoute: Hashable {
    case allAccounts
    case account(Account)
}

/// Which detail the iPad's split layout is showing. Accounts are held by id,
/// not by value: the `Account` struct changes on every sync (balances move),
/// and a stored value would stop matching its row the moment it did.
private enum AccountSelection: Hashable {
    case allAccounts
    case account(String)
}

/// One row of a budget section in the accounts list: a group header, or an
/// account under the header above it.
enum AccountListRow: Identifiable {
    case header(AccountListBucket)
    case account(Account, offset: Int, bucket: AccountListBucket)

    var id: String {
        switch self {
        case .header(let bucket): "group.\(bucket.id)"
        case .account(let account, _, _): account.id
        }
    }
}

struct AccountListBucket: Identifiable {
    let id: String
    let group: AccountGroup?
    let accounts: [Account]
}

struct AccountGroupDropTarget: Equatable {
    let before: String?
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
    @State private var path: [AccountsRoute] = []
    @State private var showingAddAccount = false
    @State private var showingAccountGroups = false
    @State private var isReordering = false
    @AppStorage("accountsCollapsedAccountGroupIDs") private var collapsedAccountGroupIDs = ""
    @State private var accountGroupBackgroundOverrides: [String: Bool] = [:]
    @State private var pendingAccountGroupTransitions: Set<String> = []
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

    private var collapsedAccountGroups: Set<String> {
        get { Set(collapsedAccountGroupIDs.split(separator: ",").map(String.init)) }
        set { collapsedAccountGroupIDs = newValue.sorted().joined(separator: ",") }
    }

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

    private var onBudgetBuckets: [AccountListBucket] {
        accountBuckets(for: filteredOnBudgetAccounts)
    }

    private var offBudgetBuckets: [AccountListBucket] {
        accountBuckets(for: filteredOffBudgetAccounts)
    }

    private func accountBuckets(for accounts: [Account]) -> [AccountListBucket] {
        var buckets: [AccountListBucket] = []
        let groupIds = Set(budgetStore.accountGroups.map(\.id))
        let ungrouped = accounts.filter { $0.groupId.map(groupIds.contains) != true }
        if !ungrouped.isEmpty {
            buckets.append(AccountListBucket(id: "ungrouped", group: nil, accounts: ungrouped))
        }
        for group in budgetStore.accountGroups {
            let members = accounts.filter { $0.groupId == group.id }
            if !members.isEmpty {
                buckets.append(AccountListBucket(id: group.id, group: group, accounts: members))
            }
        }
        return buckets
    }

    /// A budget section as one flat run of rows, so a single `onMove` can
    /// carry an account across groups. Reorders go through `onMove` because
    /// on iPhone a row's `dropDestination` never fires when the drag starts
    /// in the same List (FB12980427).
    private func accountListRows(for buckets: [AccountListBucket]) -> [AccountListRow] {
        buckets.flatMap { bucket -> [AccountListRow] in
            let header: [AccountListRow] = bucket.group == nil ? [] : [.header(bucket)]
            let isExpanded = bucket.group.map { isSearchingAccounts || isReordering || !collapsedAccountGroups.contains($0.id) } ?? true
            guard isExpanded else { return header }
            return header + bucket.accounts.enumerated().map { .account($1, offset: $0, bucket: bucket) }
        }
    }

    /// Where a List move to `destination` lands: straight after the row
    /// above it, so below a header means the top of that group (collapsed
    /// or not). `destination` indexes the rows before the move, as List
    /// reports it.
    nonisolated static func dropSlot(in rows: [AccountListRow], at destination: Int) -> (bucket: AccountListBucket, index: Int)? {
        switch rows.prefix(destination).last {
        case .header(let bucket):
            (bucket, 0)
        case .account(_, let offset, let bucket):
            (bucket, offset + 1)
        case nil:
            if case .account(_, _, let bucket) = rows.first {
                (bucket, 0)
            } else {
                nil
            }
        }
    }

    /// ponytail: derive a group's anchor from native List move indices and the
    /// synced group order; no second drag engine or local-only ordering state.
    nonisolated static func groupDropTarget(
        in rows: [AccountListRow],
        at destination: Int,
        moving groupId: String,
        fullOrder: [String]
    ) -> AccountGroupDropTarget? {
        let visibleOrder = rows.compactMap { row -> String? in
            if case .header(let bucket) = row { return bucket.group?.id }
            return nil
        }
        guard visibleOrder.count > 1, visibleOrder.contains(groupId), fullOrder.contains(groupId) else {
            return nil
        }

        let remainingVisible = visibleOrder.filter { $0 != groupId }
        let insertionIndex = rows.prefix(destination).reduce(into: 0) { count, row in
            if case .header(let bucket) = row, let id = bucket.group?.id, id != groupId {
                count += 1
            }
        }
        var reordered = remainingVisible
        reordered.insert(groupId, at: min(insertionIndex, reordered.count))
        guard reordered != visibleOrder, let position = reordered.firstIndex(of: groupId) else { return nil }
        if reordered.indices.contains(position + 1) {
            return AccountGroupDropTarget(before: reordered[position + 1])
        }

        // Groups without accounts in this budget section still occupy the
        // shared order; anchor after the last visible group without moving them.
        let remainingFullOrder = fullOrder.filter { $0 != groupId }
        guard let previous = reordered.prefix(position).last,
              let previousIndex = remainingFullOrder.firstIndex(of: previous)
        else {
            return AccountGroupDropTarget(before: remainingFullOrder.first)
        }
        let nextIndex = remainingFullOrder.index(after: previousIndex)
        return AccountGroupDropTarget(
            before: remainingFullOrder.indices.contains(nextIndex) ? remainingFullOrder[nextIndex] : nil
        )
    }

    private func moveRow(in rows: [AccountListRow]) -> (IndexSet, Int) -> Void {
        { source, destination in
            guard let from = source.first, rows.indices.contains(from) else { return }
            switch rows[from] {
            case .account(let account, _, _):
                guard let slot = Self.dropSlot(in: rows, at: destination) else { return }
                Task {
                    do {
                        try await budgetStore.dropAccount(
                            account.id, at: slot.index, among: slot.bucket.accounts, groupId: slot.bucket.group?.id
                        )
                    } catch {
                        budgetStore.error = error.localizedDescription
                    }
                }
            case .header(let bucket):
                guard budgetStore.canReorderAccountGroups,
                      let group = bucket.group,
                      let target = Self.groupDropTarget(
                          in: rows,
                          at: destination,
                          moving: group.id,
                          fullOrder: budgetStore.accountGroups.map(\.id)
                      ) else { return }
                Task {
                    do {
                        try await budgetStore.moveAccountGroup(id: group.id, before: target.before)
                    } catch {
                        budgetStore.error = error.localizedDescription
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func accountListRow(_ row: AccountListRow, among buckets: [AccountListBucket], linked: Bool) -> some View {
        switch row {
        case .header(let bucket):
            if let group = bucket.group {
                AccountGroupListHeader(
                    group: group,
                    total: bucket.accounts.sumBalance,
                    rowPosition: accountGroupHeaderRowPosition(for: bucket, among: buckets),
                    isExpanded: isSearchingAccounts || isReordering || !collapsedAccountGroups.contains(group.id),
                    isBackgroundClear: accountGroupBackgroundIsClear(group.id),
                    allowsCollapse: !isSearchingAccounts && !isReordering,
                    totalTrailingPadding: linked ? 24 : 0,
                    action: { toggleAccountGroup(group.id) }
                )
                .moveDisabled(!isReordering || !budgetStore.canReorderAccountGroups)
            }
        case .account(let account, let offset, let bucket):
            if bucket.group != nil {
                accountCell(account, linked: linked)
                    .listRowSeparator(offset == bucket.accounts.count - 1 ? .hidden : .visible)
                    .listRowBackground(groupedAccountRowBackground(at: offset, in: bucket, among: buckets))
                    .moveDisabled(!isReordering)
            } else {
                accountCell(account, linked: linked)
                    .listRowBackground(groupRowBackground(
                        position: precedingGroupRowPosition(for: account, in: bucket, among: buckets)
                    ))
                    .moveDisabled(!isReordering)
            }
        }
    }

    /// Phone rows push the account; iPad sidebar rows drive the selection.
    @ViewBuilder
    private func accountCell(_ account: Account, linked: Bool) -> some View {
        if linked {
            NavigationLink(value: AccountsRoute.account(account)) { AccountRow(account: account) }
        } else {
            AccountRow(account: account)
                .tag(AccountSelection.account(account.id))
        }
    }

    /// Expand/collapse all touch only the open budget's groups; ids
    /// remembered for other budget files stay put (GH #130).
    nonisolated static func collapsedGroupIDs(
        _ collapsed: Set<String>, groupIDs: [String], collapsing: Bool
    ) -> String {
        let groups = collapsing ? collapsed.union(groupIDs) : collapsed.subtracting(groupIDs)
        return groups.sorted().joined(separator: ",")
    }

    private func toggleAccountGroup(_ id: String) {
        guard !pendingAccountGroupTransitions.contains(id) else { return }
        let isExpanding = collapsedAccountGroups.contains(id)
        pendingAccountGroupTransitions.insert(id)
        withTransaction(SwiftUI.Transaction(animation: nil)) {
            accountGroupBackgroundOverrides[id] = isExpanding
        }
        Task { @MainActor in
            await Task.yield()
            withAnimation(AppAnimation.disclosure) {
                var collapsedGroups = collapsedAccountGroups
                if isExpanding {
                    collapsedGroups.remove(id)
                } else {
                    collapsedGroups.insert(id)
                }
                collapsedAccountGroupIDs = collapsedGroups.sorted().joined(separator: ",")
            }
            await Task.yield()
            withTransaction(SwiftUI.Transaction(animation: nil)) {
                accountGroupBackgroundOverrides[id] = nil
            }
            pendingAccountGroupTransitions.remove(id)
        }
    }

    private func accountGroupBackgroundIsClear(_ id: String) -> Bool {
        if isSearchingAccounts {
            return true
        }
        return accountGroupBackgroundOverrides[id] ?? !collapsedAccountGroups.contains(id)
    }

    private func groupedAccountRowsRoundBottom(for bucket: AccountListBucket, among buckets: [AccountListBucket]) -> Bool {
        guard let index = buckets.firstIndex(where: { $0.id == bucket.id }),
              buckets.indices.contains(index + 1),
              let nextGroup = buckets[index + 1].group
        else { return true }
        return accountGroupBackgroundIsClear(nextGroup.id)
    }

    private func groupedAccountRowBackground(at index: Int, in bucket: AccountListBucket, among buckets: [AccountListBucket]) -> AccountGroupRowBackground {
        let roundsBottom = index == bucket.accounts.count - 1 && groupedAccountRowsRoundBottom(for: bucket, among: buckets)
        return AccountGroupRowBackground(
            position: AccountGroupRowLayout.position(roundsTop: index == 0, roundsBottom: roundsBottom)
        )
    }

    private func accountGroupHeaderRowPosition(for bucket: AccountListBucket, among buckets: [AccountListBucket]) -> AccountGroupRowPosition {
        let index = buckets.firstIndex(where: { $0.id == bucket.id }) ?? 0
        return AccountGroupRowLayout.position(
            roundsTop: index == 0,
            roundsBottom: groupedAccountRowsRoundBottom(for: bucket, among: buckets)
        )
    }

    private func precedingGroupRowPosition(for account: Account, in bucket: AccountListBucket, among buckets: [AccountListBucket]) -> AccountGroupRowPosition? {
        guard bucket.id == "ungrouped",
              bucket.accounts.last?.id == account.id,
              let group = buckets.first(where: { $0.group != nil })?.group,
              accountGroupBackgroundIsClear(group.id)
        else { return nil }
        return .last
    }

    private var filteredOnBudgetAccounts: [Account] {
        filterAccountsAndGroups(onBudgetAccounts)
    }

    private var filteredOffBudgetAccounts: [Account] {
        filterAccountsAndGroups(offBudgetAccounts)
    }

    private var filteredClosedAccounts: [Account] {
        Self.filterAccounts(closedAccounts, matching: accountSearchText)
    }

    private func filterAccountsAndGroups(_ accounts: [Account]) -> [Account] {
        let query = accountSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return accounts }
        let matchingGroupIds = Set(budgetStore.accountGroups
            .filter { $0.name.localizedCaseInsensitiveContains(query) }
            .map(\.id))
        return accounts.filter { account in
            account.name.localizedCaseInsensitiveContains(query) ||
                account.groupId.map(matchingGroupIds.contains) == true
        }
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
                                NavigationLink(value: AccountsRoute.allAccounts) {
                                    allAccountsRow
                                }
                            }
                        }
                        if !filteredOnBudgetAccounts.isEmpty {
                            Section {
                                if isOnBudgetExpanded || isSearchingAccounts || isReordering {
                                    let rows = accountListRows(for: onBudgetBuckets)
                                    ForEach(rows) { row in
                                        accountListRow(row, among: onBudgetBuckets, linked: true)
                                    }
                                    .onMove(perform: moveRow(in: rows))
                                }
                            } header: {
                                AccountSectionHeader(
                                    identifier: "on-budget",
                                    title: String(localized: "On Budget"),
                                    total: onBudgetTotal,
                                    isExpanded: isSearchingAccounts ? .constant(true) : $isOnBudgetExpanded,
                                    allowsCollapse: !isSearchingAccounts && !isReordering
                                )
                            }
                            .listSectionSeparator(.hidden)
                        }
                        if !filteredOffBudgetAccounts.isEmpty {
                            Section {
                                if isOffBudgetExpanded || isSearchingAccounts || isReordering {
                                    let rows = accountListRows(for: offBudgetBuckets)
                                    ForEach(rows) { row in
                                        accountListRow(row, among: offBudgetBuckets, linked: true)
                                    }
                                    .onMove(perform: moveRow(in: rows))
                                }
                            } header: {
                                AccountSectionHeader(
                                    identifier: "off-budget",
                                    title: String(localized: "Off Budget"),
                                    total: offBudgetTotal,
                                    isExpanded: isSearchingAccounts ? .constant(true) : $isOffBudgetExpanded,
                                    allowsCollapse: !isSearchingAccounts && !isReordering
                                )
                            }
                            .listSectionSeparator(.hidden)
                        }
                        if !filteredClosedAccounts.isEmpty {
                            Section {
                                if isClosedExpanded || isSearchingAccounts {
                                    ForEach(filteredClosedAccounts) { account in
                                        NavigationLink(value: AccountsRoute.account(account)) {
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
                    .environment(\.editMode, .constant(isReordering ? .active : .inactive))
                    // Capped like the transactions this pushes to, so a
                    // narrow-iPad account list doesn't stretch a row's balance
                    // an inch away from its name. Only here: the split
                    // layout's copy is a sidebar and sizes itself.
                    .readableWidth()
                }
            }
            .navigationDestination(for: AccountsRoute.self) { route in
                switch route {
                case .allAccounts: AccountTransactionsScreen()
                case .account(let account): AccountTransactionsScreen(account: account)
                }
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
                                if isOnBudgetExpanded || isSearchingAccounts || isReordering {
                                    let rows = accountListRows(for: onBudgetBuckets)
                                    ForEach(rows) { row in
                                        accountListRow(row, among: onBudgetBuckets, linked: false)
                                    }
                                    .onMove(perform: moveRow(in: rows))
                                }
                            } header: {
                                AccountSectionHeader(
                                    identifier: "on-budget",
                                    title: String(localized: "On Budget"),
                                    total: onBudgetTotal,
                                    isExpanded: isSearchingAccounts ? .constant(true) : $isOnBudgetExpanded,
                                    allowsCollapse: !isSearchingAccounts && !isReordering,
                                    totalTrailingPadding: 0
                                )
                            }
                            .listSectionSeparator(.hidden)
                        }
                        if !filteredOffBudgetAccounts.isEmpty {
                            Section {
                                if isOffBudgetExpanded || isSearchingAccounts || isReordering {
                                    let rows = accountListRows(for: offBudgetBuckets)
                                    ForEach(rows) { row in
                                        accountListRow(row, among: offBudgetBuckets, linked: false)
                                    }
                                    .onMove(perform: moveRow(in: rows))
                                }
                            } header: {
                                AccountSectionHeader(
                                    identifier: "off-budget",
                                    title: String(localized: "Off Budget"),
                                    total: offBudgetTotal,
                                    isExpanded: isSearchingAccounts ? .constant(true) : $isOffBudgetExpanded,
                                    allowsCollapse: !isSearchingAccounts && !isReordering,
                                    totalTrailingPadding: 0
                                )
                            }
                            .listSectionSeparator(.hidden)
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
                    .environment(\.editMode, .constant(isReordering ? .active : .inactive))
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

    private func beginReordering() {
        accountSearchText = ""
        isAccountSearchFocused = false
        isAccountSearchActive = false
        withAnimation(.easeInOut(duration: 0.2)) {
            isReordering = true
        }
    }

    private func finishReordering() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isReordering = false
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
            .safeAreaInset(edge: .top, spacing: 0) {
                if isAccountSearchActive {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField(String(localized: "Search Accounts"), text: $accountSearchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($isAccountSearchFocused)
                            .accessibilityIdentifier("accounts.searchField")
                            .onSubmit { isAccountSearchFocused = false }
                            // Focus after the conditional field joins the view tree.
                            .task { isAccountSearchFocused = true }
                        if !accountSearchText.isEmpty {
                            Button {
                                accountSearchText = ""
                                isAccountSearchFocused = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "Clear Search"))
                            .accessibilityIdentifier("accounts.searchClear")
                        }
                    }
                    .frame(minHeight: 44)
                    .padding(.horizontal, 12)
                    .background(.quaternary, in: Capsule())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .toolbar {
                if isReordering {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "Done")) {
                            finishReordering()
                        }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("accounts.reorderDone")
                    }
                }
                if !isReordering && (!hasNoAccounts || isAccountSearchActive) {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isAccountSearchActive.toggle()
                            if !isAccountSearchActive {
                                isAccountSearchFocused = false
                                accountSearchText = ""
                            }
                        } label: {
                            Image(systemName: isAccountSearchActive ? "xmark" : "magnifyingglass")
                        }
                        .accessibilityLabel(isAccountSearchActive
                            ? String(localized: "Cancel Search")
                            : String(localized: "Search Accounts"))
                        .accessibilityIdentifier("accounts.search")
                    }
                }
                if !isReordering {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAddAccount = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(String(localized: "accounts.add.title"))
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if !budgetStore.accounts.isEmpty {
                            Button {
                                if isReordering {
                                    finishReordering()
                                } else {
                                    beginReordering()
                                }
                            } label: {
                                Label(
                                    isReordering ? "Done Reordering" : "Reorder Items",
                                    systemImage: isReordering ? "checkmark" : "arrow.up.arrow.down"
                                )
                            }
                            .accessibilityIdentifier("accountsOptions.reorder")
                            Divider()
                        }
                        // Stays reachable while local groups exist, so the
                        // sheet can say why they can't be edited.
                        if budgetStore.accountGroupWritesEnabled || !budgetStore.accountGroups.isEmpty {
                            Button {
                                showingAccountGroups = true
                            } label: {
                                Label(String(localized: "Manage Account Groups"), systemImage: "folder")
                            }
                            Divider()
                        }
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
                        Button(String(localized: "Expand All Accounts"), systemImage: "chevron.down") {
                            collapsedAccountGroupIDs = Self.collapsedGroupIDs(
                                collapsedAccountGroups, groupIDs: budgetStore.accountGroups.map(\.id), collapsing: false
                            )
                            isOnBudgetExpanded = true
                            isOffBudgetExpanded = true
                            isClosedExpanded = true
                        }
                        .accessibilityIdentifier("accounts.expandAll")
                        Button(String(localized: "Collapse All Accounts"), systemImage: "chevron.right") {
                            collapsedAccountGroupIDs = Self.collapsedGroupIDs(
                                collapsedAccountGroups, groupIDs: budgetStore.accountGroups.map(\.id), collapsing: true
                            )
                            isOnBudgetExpanded = false
                            isOffBudgetExpanded = false
                            isClosedExpanded = false
                        }
                        .accessibilityIdentifier("accounts.collapseAll")
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
                    .accessibilityIdentifier("accounts.optionsMenu")
                }
                if pendingImportStore.count > 0 && !isReordering {
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
            .sheet(isPresented: $showingAccountGroups) {
                AccountGroupsSheet().environmentObject(budgetStore)
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
                consumePendingSavedTransactionNavigation()
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
            .onChange(of: notificationRouter.pendingSavedTransactionAccount) { _, accountId in
                if accountId != nil {
                    consumePendingSavedTransactionNavigation()
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
            path = [.allAccounts]
        }
        notificationRouter.pendingAllAccountsNavigation = false
    }

    /// A credit card reminder tap lands here: jump the stack straight to the
    /// card's account (replacing anything the user had pushed) and clear the
    /// signal. onChange covers the usual case; onAppear covers a tap before
    /// this tab was ever created, when the signal is already pending as the
    /// view first appears.
    private func consumePendingAccountNavigation() {
        guard let accountId = notificationRouter.pendingAccountNavigation else { return }
        notificationRouter.pendingAccountNavigation = nil
        showAccount(accountId)
    }

    /// A save in the tab-hosted add flow lands here, the same way, except
    /// that All Accounts stays showing: it already lists the saved
    /// transaction (GH #722).
    private func consumePendingSavedTransactionNavigation() {
        guard let accountId = notificationRouter.pendingSavedTransactionAccount else { return }
        notificationRouter.pendingSavedTransactionAccount = nil
        let showsAllAccounts = usesSplitLayout ? selection == .allAccounts : path.last == .allAccounts
        if !showsAllAccounts {
            showAccount(accountId)
        }
    }

    private func showAccount(_ accountId: String) {
        guard let account = budgetStore.accounts.first(where: { $0.id == accountId }) else { return }
        if usesSplitLayout {
            selection = .account(account.id)
        } else {
            path = [.account(account)]
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
                if identifier == "closed" {
                    DisclosureChevron(isExpanded: isExpanded)
                        .frame(width: 12)
                    sectionTitle
                }
                Spacer()
                Text(totalText)
                    .font(.headline.weight(.regular))
                    .foregroundStyle(balanceColor(for: total))
                    .animatedAmount(totalText)
                    .padding(.trailing, identifier == "closed" ? totalTrailingPadding : 20)
                    // Grouped-list headers uppercase their content; fine for
                    // the title (string headers always rendered that way) but
                    // it would mangle alphabetic currency symbols ("kr"→"KR").
                    .textCase(nil)
                    // One line always: a narrow sidebar wraps "USD 48,800.00"
                    // onto two lines rather than shrinking it.
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .overlay(alignment: .leading) {
                if identifier != "closed" {
                    sectionTitle
                        .padding(.leading, 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .trailing) {
                if identifier != "closed" {
                    DisclosureChevron(isExpanded: isExpanded)
                        .frame(width: 12, height: 20)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!allowsCollapse)
        .listRowSeparator(.hidden)
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

    private var sectionTitle: some View {
        Text(title)
            .font(.headline.weight(.semibold))
            .textCase(nil)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

private struct AccountGroupListHeader: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    let group: AccountGroup
    let total: Int
    let rowPosition: AccountGroupRowPosition
    let isExpanded: Bool
    let isBackgroundClear: Bool
    let allowsCollapse: Bool
    /// Sidebar rows have no NavigationLink chevron, so they pass zero to keep
    /// group totals aligned with the account balances below.
    var totalTrailingPadding: CGFloat = 24
    let action: () -> Void

    var body: some View {
        let totalText = budgetStore.displayBalance(total)
        Button {
            if allowsCollapse {
                action()
            }
        } label: {
            HStack(spacing: 7) {
                Text(group.name)
                    .font(.body.weight(.bold))
                    .foregroundStyle(isExpanded ? .secondary : .primary)
                Spacer()
                AccountGroupTotal(totalText: totalText, total: total)
                    .padding(.trailing, totalTrailingPadding)
            }
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                DisclosureChevron(isExpanded: isExpanded)
                    .frame(width: 10)
                    .offset(x: -20)
            }
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 5, leading: 28, bottom: 5, trailing: 16))
        .listRowBackground(rowBackground)
        .listRowSeparator(isBackgroundClear ? .hidden : .visible, edges: .top)
        .listRowSeparator(.hidden, edges: .bottom)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(String(format: String(localized: "accounts.group.accessibility"), group.name, isExpanded ? String(localized: "expanded") : String(localized: "collapsed"), totalText))
        .accessibilityIdentifier("account.subgroup.\(group.id)")
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isBackgroundClear {
            Color.clear.transaction {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        } else {
            AccountGroupRowBackground(position: rowPosition)
        }
    }
}

enum AccountGroupRowPosition: Equatable {
    case single
    case first
    case middle
    case last
}

enum AccountGroupRowLayout {
    static func position(roundsTop: Bool, roundsBottom: Bool) -> AccountGroupRowPosition {
        switch (roundsTop, roundsBottom) {
        case (true, true): .single
        case (true, false): .first
        case (false, true): .last
        case (false, false): .middle
        }
    }
}

private struct AccountGroupRowBackground: View {
    let position: AccountGroupRowPosition

    var body: some View {
        let topRadius: CGFloat = position == .single || position == .first ? 16 : 0
        let bottomRadius: CGFloat = position == .single || position == .last ? 16 : 0

        UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius
        )
        .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }
}

private func groupRowBackground(position: AccountGroupRowPosition?) -> AnyView? {
    position.map { AnyView(AccountGroupRowBackground(position: $0)) }
}

private struct AccountGroupTotal: View {
    let totalText: String
    let total: Int

    var body: some View {
        Text(totalText)
            .font(.body)
            .foregroundStyle(balanceColor(for: total))
            .textCase(nil)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct AccountRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let account: Account
    @State private var isCreatingGroup = false
    @State private var newGroupName = ""

    var body: some View {
        // The group menu is the only context-menu item, so without it there
        // is no menu at all rather than an empty one.
        if budgetStore.accountGroupWritesEnabled {
            row.contextMenu { groupMenu }
        } else {
            row
        }
    }

    private var row: some View {
        let balance = budgetStore.displayBalance(account.balance)
        return HStack {
            Text(account.name)
                .font(.body)
                .padding(.leading, 8)
            Spacer()
            Text(balance)
                .foregroundStyle(balanceColor(for: account.balance))
                .animatedAmount(balance)
        }
        .alert(String(localized: "Create Group"), isPresented: $isCreatingGroup) {
            TextField(String(localized: "Group Name"), text: $newGroupName)
            Button(String(localized: "Add")) {
                let groupName = newGroupName
                Task { try? await budgetStore.createAccountGroup(name: groupName, assignTo: account) }
            }
            .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }

    private var groupMenu: some View {
        Menu(String(localized: "Set Account Group"), systemImage: "folder") {
            Button(String(localized: "None")) { Task { try? await budgetStore.setAccountGroup(account, groupId: nil) } }
            ForEach(budgetStore.accountGroups) { group in
                Button(group.name) { Task { try? await budgetStore.setAccountGroup(account, groupId: group.id) } }
            }
            Divider()
            Button {
                newGroupName = ""
                isCreatingGroup = true
            } label: {
                Label(String(localized: "Add New"), systemImage: "plus")
            }
        }
    }
}

private struct AccountGroupsSheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isRenaming = false
    @State private var renameName = ""
    @State private var renameTarget: AccountGroup?

    private func moveGroup(from source: IndexSet, to destination: Int) {
        guard budgetStore.accountGroupWritesEnabled,
              source.count == 1,
              let index = source.first,
              budgetStore.accountGroups.indices.contains(index) else { return }
        let original = budgetStore.accountGroups
        var reordered = original
        reordered.move(fromOffsets: source, toOffset: destination)
        guard reordered.map(\.id) != original.map(\.id),
              let movedIndex = reordered.firstIndex(where: { $0.id == original[index].id }) else { return }
        let before = reordered.indices.contains(movedIndex + 1) ? reordered[movedIndex + 1].id : nil
        Task {
            do {
                try await budgetStore.moveAccountGroup(id: original[index].id, before: before)
            } catch {
                budgetStore.error = error.localizedDescription
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if budgetStore.accountGroupWritesEnabled {
                    Section(String(localized: "Create Group")) {
                        HStack {
                            TextField(String(localized: "Group Name"), text: $name)
                            Button(String(localized: "Add")) {
                                Task { try? await budgetStore.createAccountGroup(name: name); name = "" }
                            }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                Section {
                    ForEach(budgetStore.accountGroups) { group in
                        HStack {
                            Text(group.name)
                            Spacer()
                            Button(String(localized: "Rename")) {
                                renameTarget = group
                                renameName = group.name
                                isRenaming = true
                            }
                            Button(role: .destructive) {
                                Task { try? await budgetStore.deleteAccountGroup(group) }
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(!budgetStore.accountGroupWritesEnabled)
                        .moveDisabled(!budgetStore.accountGroupWritesEnabled)
                    }
                    .onMove(perform: moveGroup)
                } header: {
                    Text(String(localized: "Account Groups"))
                } footer: {
                    if !budgetStore.accountGroupWritesEnabled {
                        Text(String(localized: "Account groups require Actual Server 26.9.0 or later."))
                    }
                }
            }
            .navigationTitle(String(localized: "Account Groups"))
            .toolbar {
                if budgetStore.accountGroupWritesEnabled {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                            .accessibilityIdentifier("accountGroups.edit")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .alert(String(localized: "Rename Group"), isPresented: $isRenaming) {
                TextField(String(localized: "Group Name"), text: $renameName)
                Button(String(localized: "Save")) {
                    if let renameTarget {
                        Task { try? await budgetStore.renameAccountGroup(renameTarget, name: renameName) }
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            }
        }
    }
}

#Preview {
    AccountsListView()
        .environmentObject(BudgetStore.previewInstance())
}
