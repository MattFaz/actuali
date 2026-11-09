import SwiftUI

/// Value-based routes for the phone stack. Typed rather than a
/// `NavigationPath` so a notification tap can reset the stack onto All
/// Accounts, and a save can tell when All Accounts is already showing.
private enum AccountsRoute: Hashable {
    case allAccounts
    case onBudgetTransactions
    case offBudgetTransactions
    case account(Account)
}

/// Which detail the iPad's split layout is showing. Accounts are held by id,
/// not by value: the `Account` struct changes on every sync (balances move),
/// and a stored value would stop matching its row the moment it did.
private enum AccountSelection: Hashable {
    case allAccounts
    case onBudgetTransactions
    case offBudgetTransactions
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

    nonisolated static func buckets(for accounts: [Account], groups: [AccountGroup]) -> [AccountListBucket] {
        var buckets: [AccountListBucket] = []
        let groupIds = Set(groups.map(\.id))
        let ungrouped = accounts.filter { $0.groupId.map(groupIds.contains) != true }
        if !ungrouped.isEmpty {
            buckets.append(AccountListBucket(id: "ungrouped", group: nil, accounts: ungrouped))
        }
        for group in groups {
            let members = accounts.filter { $0.groupId == group.id }
            if !members.isEmpty {
                buckets.append(AccountListBucket(id: group.id, group: group, accounts: members))
            }
        }
        return buckets
    }
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
        AccountListBucket.buckets(for: accounts, groups: budgetStore.accountGroups)
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
            if case .header(let bucket) = row {
                return bucket.group?.id
            }
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
        guard position > 0,
              let previousIndex = remainingFullOrder.firstIndex(of: reordered[position - 1]) else { return nil }
        let nextIndex = remainingFullOrder.index(after: previousIndex)
        return AccountGroupDropTarget(
            before: remainingFullOrder.indices.contains(nextIndex) ? remainingFullOrder[nextIndex] : nil
        )
    }

    nonisolated static func groupMoveTarget(
        in groups: [AccountGroup],
        from source: IndexSet,
        to destination: Int
    ) -> AccountGroupDropTarget? {
        guard source.count == 1,
              let index = source.first,
              groups.indices.contains(index),
              (0...groups.count).contains(destination) else { return nil }
        var reordered = groups
        reordered.move(fromOffsets: source, toOffset: destination)
        guard reordered.map(\.id) != groups.map(\.id),
              let moved = reordered.firstIndex(where: { $0.id == groups[index].id }) else { return nil }
        return AccountGroupDropTarget(
            before: reordered.indices.contains(moved + 1) ? reordered[moved + 1].id : nil
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
                    .listRowBackground(AccountGroupRowBackground(
                        position: AccountGroupRowLayout.position(
                            roundsTop: offset == 0,
                            roundsBottom: offset == bucket.accounts.count - 1
                        )
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

    private func closedRowBackground(at index: Int) -> AccountGroupRowBackground {
        AccountGroupRowBackground(position: AccountGroupRowLayout.position(
            roundsTop: index == 0,
            roundsBottom: index == filteredClosedAccounts.count - 1
        ))
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
        Self.filterAccounts(accounts, groups: budgetStore.accountGroups, matching: accountSearchText)
    }

    /// Matches an account by its own name or by its custom group's name.
    nonisolated static func filterAccounts(_ accounts: [Account], groups: [AccountGroup], matching query: String) -> [Account] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return accounts }
        let matchingGroupIds = Set(groups
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
                                    allowsCollapse: !isSearchingAccounts && !isReordering,
                                    onShowTransactions: { path.append(.onBudgetTransactions) }
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
                                    allowsCollapse: !isSearchingAccounts && !isReordering,
                                    onShowTransactions: { path.append(.offBudgetTransactions) }
                                )
                            }
                            .listSectionSeparator(.hidden)
                        }
                        if !filteredClosedAccounts.isEmpty {
                            Section {
                                if isClosedExpanded || isSearchingAccounts {
                                    ForEach(Array(filteredClosedAccounts.enumerated()), id: \.element.id) { offset, account in
                                        NavigationLink(value: AccountsRoute.account(account)) {
                                            AccountRow(account: account)
                                        }
                                        .listRowBackground(closedRowBackground(at: offset))
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
                    // Keep native search attached to the List itself so iOS can focus its search field.
                    .onDemandSearch(
                        text: $accountSearchText,
                        isPresented: $isAccountSearchActive,
                        isFocused: $isAccountSearchFocused,
                        prompt: "Search Accounts",
                        accessibilityPrefix: "accounts"
                    )
                    .environment(\.editMode, .constant(isReordering ? .active : .inactive))
                    .pinnedSectionHeaders()
                    .safeAreaInset(edge: .top, spacing: 0) {
                        pinnedSummary {
                            NavigationLink(value: AccountsRoute.allAccounts) { allAccountsCard }
                        }
                    }
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
                case .onBudgetTransactions: AccountTransactionsScreen(scope: .onBudget)
                case .offBudgetTransactions: AccountTransactionsScreen(scope: .offBudget)
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
                                    onShowTransactions: { selection = .onBudgetTransactions }
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
                                    onShowTransactions: { selection = .offBudgetTransactions }
                                )
                            }
                            .listSectionSeparator(.hidden)
                        }
                        if !filteredClosedAccounts.isEmpty {
                            Section {
                                if isClosedExpanded || isSearchingAccounts {
                                    ForEach(Array(filteredClosedAccounts.enumerated()), id: \.element.id) { offset, account in
                                        AccountRow(account: account)
                                            .tag(AccountSelection.account(account.id))
                                            .listRowBackground(closedRowBackground(at: offset))
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
                    .onDemandSearch(
                        text: $accountSearchText,
                        isPresented: $isAccountSearchActive,
                        isFocused: $isAccountSearchFocused,
                        prompt: "Search Accounts",
                        accessibilityPrefix: "accounts"
                    )
                    .environment(\.editMode, .constant(isReordering ? .active : .inactive))
                    .pinnedSectionHeaders()
                    .safeAreaInset(edge: .top, spacing: 0) {
                        pinnedSummary {
                            Button { selection = .allAccounts } label: { allAccountsCard }
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
                case .onBudgetTransactions:
                    AccountTransactionsScreen(scope: .onBudget)
                case .offBudgetTransactions:
                    AccountTransactionsScreen(scope: .offBudget)
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

    /// The card as Budget draws its summary, so the two tabs' summaries line up.
    private var allAccountsCard: some View {
        AccountsSummaryCard(totalBalance: totalBalance, monthTotals: monthSummary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }

    /// Kept outside the List so it stays put while the accounts scroll, like
    /// the Budget summary (GH #155). Hidden while searching, as the in-list
    /// row was.
    @ViewBuilder
    private func pinnedSummary(@ViewBuilder _ link: () -> some View) -> some View {
        if !isSearchingAccounts {
            link()
                .buttonStyle(.plain)
                .accessibilityIdentifier("accounts.topBox")
                .padding(.horizontal, TopBoxLayout.horizontalContentMargin)
                .padding(.top, TopBoxLayout.verticalContentMargin)
                // Twice the top gutter: the room the later section bars get
                // from the gap between sections, so On Budget isn't squat.
                .padding(.bottom, TopBoxLayout.verticalContentMargin * 2)
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
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

    /// Shared presentation for both account-list layouts: margins, empty search
    /// results, and toolbar items. Search itself stays attached to each List.
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
            // Searching filters the rows a drag moves among, so reordering and
            // search stay mutually exclusive (beginReordering clears search).
            .onChange(of: isAccountSearchActive) { _, active in
                if active {
                    finishReordering()
                }
            }
            // The List carrying search leaves with the last account; don't
            // reopen it with a stale query when accounts come back.
            .onChange(of: hasNoAccounts) { _, empty in
                guard empty else { return }
                isAccountSearchActive = false
                isAccountSearchFocused = false
                accountSearchText = ""
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
                if pendingImportStore.count > 0, !isReordering {
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
    var scope: AccountTransactionsScope?

    var body: some View {
        Group {
            if let account {
                AccountDetailView(account: account)
            } else {
                TransactionsListView(scope: scope)
                    .id(scope?.rawValue ?? "all")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if budgetStore.showTransactionStatusFilters {
                TransactionFilterStrip(
                    selection: $budgetStore.transactionStatusFilter,
                    filters: account?.offBudget == true || scope == .offBudget
                        ? TransactionStatusFilter.allCases.filter { $0 != .uncategorized }
                        : TransactionStatusFilter.allCases
                )
            }
        }
        .task(id: "\(account?.id ?? "")|\(scope?.rawValue ?? "")") {
            if account?.offBudget == true || scope == .offBudget,
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
/// The budget sections split into two buttons: the title and arrow open that
/// section's transactions, the total and chevron expand/collapse it. Closed
/// Accounts has no transactions list, so its whole header collapses.
struct AccountSectionHeader: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let identifier: String
    let title: String
    let total: Int
    @Binding var isExpanded: Bool
    var allowsCollapse = true
    var onShowTransactions: (() -> Void)?
    /// Extra trailing inset lining the Closed total up with row balances that
    /// sit left of a NavigationLink disclosure chevron. The split layout's rows
    /// carry no chevron, so it passes zero to keep its totals flush too.
    var totalTrailingPadding: CGFloat = 24

    var body: some View {
        let totalText = budgetStore.displayBalance(total)
        Group {
            if let onShowTransactions {
                HStack(spacing: 0) {
                    Button(action: onShowTransactions) {
                        HStack(spacing: 8) {
                            sectionTitle
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 8)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!allowsCollapse)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(String(format: String(localized: "Show %@ transactions"), title))
                    .accessibilityIdentifier("account.group.\(identifier).transactions")
                    .accessibilityHint(String(localized: "Opens transactions for this budget group"))

                    Button {
                        isExpanded.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Text(totalText)
                                .font(.headline.weight(.regular))
                                .foregroundStyle(balanceColor(for: total))
                                .animatedAmount(totalText)
                                // Grouped-list headers uppercase their content,
                                // which would mangle currency symbols ("kr"→"KR").
                                .textCase(nil)
                                // One line always: a narrow sidebar would wrap it.
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            DisclosureChevron(isExpanded: isExpanded)
                                .frame(width: 12, height: 20)
                                .accessibilityHidden(true)
                        }
                        .padding(.leading, 8)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!allowsCollapse)
                    .accessibilityLabel(
                        String(
                            format: String(localized: "accounts.group.accessibility"),
                            title,
                            expandedState,
                            totalText
                        )
                    )
                    .accessibilityIdentifier("account.group.\(identifier).disclosure")
                    .accessibilityHint(collapseHint)
                }
            } else {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        DisclosureChevron(isExpanded: isExpanded)
                            .frame(width: 12)
                            .accessibilityHidden(true)
                        sectionTitle
                        Spacer(minLength: 8)
                        Text(totalText)
                            .font(.headline.weight(.regular))
                            .foregroundStyle(balanceColor(for: total))
                            .animatedAmount(totalText)
                            .padding(.trailing, totalTrailingPadding)
                            .textCase(nil)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!allowsCollapse)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(
                    String(
                        format: String(localized: "accounts.group.accessibility"),
                        title,
                        expandedState,
                        totalText
                    )
                )
                .accessibilityIdentifier("account.group.\(identifier)")
                .accessibilityHint(collapseHint)
            }
        }
        .listRowSeparator(.hidden)
        // Pinned, so rows scrolling beneath must not show through: take the
        // container's insets away and put the horizontal one back inside.
        .padding(.horizontal, 16)
        .listRowInsets(EdgeInsets())
        .background(Color(.systemGroupedBackground))
    }

    private var collapseHint: String {
        guard allowsCollapse else { return "" }
        return isExpanded
            ? String(localized: "Collapses this section")
            : String(localized: "Expands this section")
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
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                DisclosureChevron(isExpanded: isExpanded)
                    .frame(width: 10)
                    .offset(x: -20)
            }
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 16))
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

/// Circular badge with an SF Symbol for the account type, or for the loan,
/// deposit or credit card it tracks. Symbols follow `AccountBalanceWidget.iconName`.
struct AccountTypeAvatar: View {
    let account: Account
    var hasLoan: Bool = false
    var hasDeposit: Bool = false
    var hasCreditCard: Bool = false

    // ponytail: icon derived from account.type and active configs only.
    // Ceiling: no vehicle/personal split for loans. Upgrade path: store
    // the loan instrument kind on LoanConfig when the loan editor gains the field.
    nonisolated static func icon(
        for type: AccountType,
        hasDeposit: Bool = false,
        hasLoan: Bool = false,
        hasCreditCard: Bool = false
    ) -> String {
        if hasDeposit {
            return "lock.fill"
        }
        if hasLoan {
            return "house.fill"
        }
        if hasCreditCard {
            return "creditcard.fill"
        }
        return defaultTypeIcon(for: type)
    }

    nonisolated static func defaultTypeIcon(for type: AccountType) -> String {
        switch type {
        case .checking: "banknote.fill"
        case .savings: "building.columns.fill"
        case .credit: "creditcard.fill"
        case .mortgage: "house.fill"
        case .debt: "exclamationmark.triangle.fill"
        case .investment: "chart.line.uptrend.xyaxis"
        case .other: "dollarsign.circle.fill"
        }
    }

    /// Icon color; the badge fills with the same color at low opacity.
    nonisolated static func iconColor(
        for type: AccountType,
        hasDeposit: Bool = false,
        hasLoan: Bool = false,
        hasCreditCard: Bool = false,
        closed: Bool = false
    ) -> Color {
        if closed {
            return .secondary
        }
        if hasDeposit {
            return .green
        }
        if hasLoan {
            return .blue
        }
        if hasCreditCard {
            return .orange
        }
        switch type {
        case .checking, .mortgage, .debt: return .blue
        case .savings: return .purple
        case .credit: return .orange
        case .investment: return .green
        case .other: return .primary
        }
    }

    var body: some View {
        let color = Self.iconColor(
            for: account.type,
            hasDeposit: hasDeposit,
            hasLoan: hasLoan,
            hasCreditCard: hasCreditCard,
            closed: account.closed
        )
        ZStack {
            Circle().fill(color.opacity(0.18))
            Image(systemName: Self.icon(
                for: account.type,
                hasDeposit: hasDeposit,
                hasLoan: hasLoan,
                hasCreditCard: hasCreditCard
            ))
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
        }
        .frame(width: 36, height: 36)
    }
}

struct AccountRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let account: Account
    @AppStorage("showAccountTypeIcons") private var showAccountTypeIcons = true

    @State private var isCreatingGroup = false
    @State private var isRenamingAccount = false
    @State private var newGroupName = ""
    @State private var renameName = ""
    @State private var isClosing = false

    /// Share of payoff or term completed (0...1), or nil when the account has no tracking.
    /// Pure so tests can exercise all combinations of loan, deposit, and credit card configs.
    nonisolated static func progress(
        for account: Account,
        loanConfig: LoanConfig?,
        depositConfig: DepositConfig?,
        creditCardDues: [CreditCardCycle.StatementDue]?,
        today: DayDate = .today()
    ) -> Double? {
        guard !account.closed else { return nil }
        if let loanConfig {
            return loanConfig.fractionPaidOff(accountBalance: account.balance)
        }
        if let depositConfig {
            return depositConfig.fractionElapsed(on: today)
        }
        // remainingDue never exceeds statementBalance (calculateStatementDue), so this stays in 0...1.
        guard let dues = creditCardDues,
              let due = CreditCardCycle.pendingStatementDue(in: dues, today: today),
              due.statementBalance > 0 else { return nil }
        return Double(due.statementBalance - due.remainingDue) / Double(due.statementBalance)
    }

    /// One account is one instrument, so a bar that is neither loan nor
    /// deposit is a tracked card, whatever the account's type.
    nonisolated static func progressBarColor(p: Double, hasLoan: Bool, hasDeposit: Bool) -> Color {
        if p >= 1.0 || hasDeposit {
            return .green
        }
        return hasLoan ? .blue : .red
    }

    var body: some View {
        row
            .contextMenu {
                Button {
                    renameName = account.name
                    isRenamingAccount = true
                } label: {
                    Label(String(localized: "Rename Account"), systemImage: "pencil")
                }
                .accessibilityIdentifier("accountRename.action")

                if budgetStore.accountGroupWritesEnabled {
                    groupMenu
                }
                typeMenu
                closeMenu
            }
            .sheet(isPresented: $isClosing) {
                CloseAccountSheet(account: account)
            }
    }

    private func commitRename() {
        let name = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != account.name else { return }
        Task {
            do {
                try await budgetStore.renameAccount(id: account.id, name: name)
            } catch {
                budgetStore.error = error.localizedDescription
            }
        }
    }

    private var typeMenu: some View {
        Menu(String(localized: "accounts.type.title"), systemImage: "tag") {
            ForEach(AccountType.allCases, id: \.self) { type in
                Button {
                    Task {
                        do {
                            try await budgetStore.setAccountType(account, type: type)
                        } catch {
                            budgetStore.error = error.localizedDescription
                        }
                    }
                } label: {
                    if account.type == type {
                        Label(type.title, systemImage: "checkmark")
                    } else {
                        Text(type.title)
                    }
                }
            }
        }
        .accessibilityIdentifier("accountRow.type.\(account.id)")
    }

    @ViewBuilder
    private var closeMenu: some View {
        if account.closed {
            Button {
                Task { try? await budgetStore.reopenAccount(account) }
            } label: {
                Label(String(localized: "Reopen Account"), systemImage: "arrow.uturn.backward")
            }
            .accessibilityIdentifier("accountRow.reopen.\(account.id)")
        } else {
            Button(role: .destructive) {
                isClosing = true
            } label: {
                Label(String(localized: "Close Account"), systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("accountRow.close.\(account.id)")
        }
    }

    private var row: some View {
        let balance = budgetStore.displayBalance(account.balance)
        let loanConfig = budgetStore.activeLoanConfig(for: account.id)
        let depositConfig = budgetStore.activeDepositConfig(for: account.id)
        let hasLoan = loanConfig != nil
        let hasDeposit = depositConfig != nil
        let hasCreditCard = budgetStore.activeCreditCardCycle(for: account.id) != nil
        let progress = Self.progress(
            for: account,
            loanConfig: loanConfig,
            depositConfig: depositConfig,
            creditCardDues: budgetStore.creditCardStatementDues[account.id]
        )

        return HStack(alignment: .center, spacing: 12) {
            if showAccountTypeIcons {
                AccountTypeAvatar(
                    account: account,
                    hasLoan: hasLoan,
                    hasDeposit: hasDeposit,
                    hasCreditCard: hasCreditCard
                )
                .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(account.name)
                        .font(.body)
                    Spacer()
                    Text(balance)
                        .foregroundStyle(balanceColor(for: account.balance))
                        .animatedAmount(balance)
                }
                if let p = progress {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .tint(Self.progressBarColor(p: p, hasLoan: hasLoan, hasDeposit: hasDeposit))
                        .accessibilityIdentifier("accountRow.progress.\(account.id)")
                }
            }
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
        .alert(String(localized: "Rename Account"), isPresented: $isRenamingAccount) {
            TextField(String(localized: "Account Name"), text: $renameName)
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Save")) {
                commitRename()
            }
            .disabled(renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        let groups = budgetStore.accountGroups
        guard budgetStore.canReorderAccountGroups,
              let index = source.first,
              groups.indices.contains(index),
              let target = AccountsListView.groupMoveTarget(in: groups, from: source, to: destination) else { return }
        Task {
            do {
                try await budgetStore.moveAccountGroup(id: groups[index].id, before: target.before)
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
                        .moveDisabled(!budgetStore.canReorderAccountGroups)
                    }
                    .onMove(perform: moveGroup)
                } header: {
                    Text(String(localized: "Account Groups"))
                } footer: {
                    if !budgetStore.canReorderAccountGroups {
                        Text(String(localized: "Account groups require Actual Server 26.9.0 or later."))
                    }
                }
            }
            .navigationTitle(String(localized: "Account Groups"))
            .toolbar {
                if budgetStore.canReorderAccountGroups {
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

/// Close flow for one account (upstream `closeAccount`): a non-zero balance
/// needs a destination account, plus a category when the money leaves the
/// budget for an off-budget account.
private struct CloseAccountSheet: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let account: Account
    @State private var transferAccountId: String?
    @State private var categoryId: String?
    @State private var errorMessage: String?
    @State private var isConfirmingForceClose = false

    private var destinations: [Account] {
        budgetStore.accounts.filter { !$0.closed && $0.id != account.id }
    }

    /// Upstream asks only when an on-budget account empties into an
    /// off-budget one, and won't close until a category is picked.
    private var needsCategory: Bool {
        BudgetStore.transferLegTakesCategory(
            leg: account.id,
            partner: transferAccountId,
            offBudgetAccountIds: budgetStore.offBudgetAccountIds
        )
    }

    private var canClose: Bool {
        account.balance == 0 || (transferAccountId != nil && (!needsCategory || categoryId != nil))
    }

    var body: some View {
        NavigationStack {
            Form {
                if account.balance != 0 {
                    Section {
                        Picker(String(localized: "Move Balance To"), selection: $transferAccountId) {
                            Text(String(localized: "Select Account")).tag(String?.none)
                            ForEach(destinations) { Text($0.name).tag(String?.some($0.id)) }
                        }
                        .accessibilityIdentifier("closeAccount.destination")
                        if needsCategory {
                            Picker(String(localized: "Category"), selection: $categoryId) {
                                Text(String(localized: "Select a category")).tag(String?.none)
                                ForEach(budgetStore.categoryGroups.filter { !$0.isIncome }) { group in
                                    ForEach(group.categories) { Text($0.name).tag(String?.some($0.id)) }
                                }
                            }
                            .accessibilityIdentifier("closeAccount.category")
                        }
                    } footer: {
                        Text(String(
                            localized: "The remaining balance of \(budgetStore.displayBalance(account.balance)) moves to the selected account."
                        ))
                    }
                } else {
                    Section {
                        Text(String(localized: "Closed accounts stay in your history but no longer accept new transactions."))
                    }
                }
                Section {
                    Button(String(localized: "Delete Account and Transactions"), role: .destructive) {
                        isConfirmingForceClose = true
                    }
                    .accessibilityIdentifier("closeAccount.forceClose")
                } footer: {
                    Text(String(localized: "Removes the account and every transaction in it. Transfers in other accounts stay but lose their link. This can't be undone."))
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .confirmationDialog(
                String(localized: "Delete this account and all its transactions?"),
                isPresented: $isConfirmingForceClose,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Delete Account and Transactions"), role: .destructive) {
                    Task {
                        do {
                            try await budgetStore.forceCloseAccount(account)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Close Account"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Close")) {
                        Task {
                            do {
                                try await budgetStore.closeAccount(
                                    account,
                                    transferAccountId: transferAccountId,
                                    categoryId: needsCategory ? categoryId : nil
                                )
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(!canClose)
                    .accessibilityIdentifier("closeAccount.confirm")
                }
            }
        }
    }
}

private extension View {
    /// Grouped List headers scroll away; the plain style pins them (as
    /// Budget's group headers are, GH #610). The grouped look is put back
    /// by hand: no default background, the grouped canvas colour behind.
    func pinnedSectionHeaders() -> some View {
        listStyle(.plain)
            // The plain style's stock minimum is taller than the 44 pt header
            // rows, which would leave group rows taller than the section bars.
            .environment(\.defaultMinListRowHeight, 44)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
    }
}
