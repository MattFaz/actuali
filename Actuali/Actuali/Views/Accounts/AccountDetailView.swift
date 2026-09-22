import SwiftUI

struct AccountDetailView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let account: Account

    @State private var pager: TransactionPager?
    /// Which account `pager` was built for. The iPad split layout reuses one
    /// instance of this view across selections, so the account can change
    /// under state that was scoped to the previous one.
    @State private var pagerAccountId: String?
    @State private var breakdown: AccountBalanceBreakdown?
    @State private var showingBreakdown = false
    @State private var showingBillingCycle = false
    @State private var showingLoanDetails = false
    @State private var showingLoanEditor = false
    @State private var searchText = ""
    @State private var showingAddTransaction = false
    @State private var showingReconcile = false
    @State private var showingWalletImport = false
    @State private var editingTransaction: Transaction?
    /// The account's note (GH #198). Starts `.unsupported` so the menu item
    /// stays hidden until the read confirms this file can store notes.
    @State private var note: EntityNote = .unsupported
    @State private var editingNote = false
    @AppStorage("accountsHideNotes") private var hideNotes = false
    @State private var isSelecting = false
    @State private var selectedTransactionIds: Set<String> = []
    @State private var cycleSpend: Int = 0
    @AppStorage("showAccountRunningBalance") private var showRunningBalance = true
    @State private var loadedFullHistory = false
    @State private var recentStatements: [CreditCardCycle.StatementRecord] = []
    @State private var selectedStatement: CreditCardCycle.StatementRecord? = nil

    private var statementDue: CreditCardCycle.StatementDue? {
        guard let dues = budgetStore.creditCardStatementDues[account.id] else { return nil }
        let today = DayDate.today()
        return dues.first { today <= $0.dueDate && $0.remainingDue > 0 }
            ?? dues.first { today <= $0.dueDate }
    }

    private var currentBalance: Int {
        budgetStore.accounts.first { $0.id == account.id }?.balance ?? account.balance
    }

    /// Running balances are shown only when the register is unfiltered (no search,
    /// status chip, and not hiding cleared/reconciled rows). Filtered/search results
    /// omit rows that would otherwise contribute to the balance, so showing a running
    /// balance in those states would make it look like the account balance changed when
    /// the user only changed the visible filter.
    private var shouldShowRunningBalance: Bool {
        showRunningBalance && loadedFullHistory
    }

    private var transactionsForDisplay: [Transaction] {
        guard shouldShowRunningBalance else { return pager?.transactions ?? [] }
        return (pager?.transactions ?? []).withRunningBalances(startingAt: currentBalance)
    }

    /// Limit and headroom for a tracked card with a limit set, else nil. Read
    /// once so the visible row and the breakdown row can't disagree.
    private var creditHeadroom: (limit: Int, available: Int)? {
        guard let available = budgetStore.availableCredit(for: account.id),
              let limit = budgetStore.creditCardLimits[account.id] else { return nil }
        return (limit, available)
    }

    private var searchQuery: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What the Recent Transactions section says when it has no rows. A
    /// search or a status chip gets the neutral message; the hide toggles
    /// name themselves so the user knows which menu item to flip back.
    private var emptyTransactionsText: LocalizedStringKey {
        Self.emptyTransactionsText(
            isSearching: searchQuery != nil,
            statusFilter: budgetStore.transactionStatusFilter,
            hideCleared: budgetStore.hideClearedTransactions,
            hideReconciled: budgetStore.hideReconciledTransactions
        )
    }

    /// Pure so tests can reach every branch without a view (same seam as
    /// `MonthPicker.title`).
    nonisolated static func emptyTransactionsText(
        isSearching: Bool,
        statusFilter: TransactionStatusFilter,
        hideCleared: Bool,
        hideReconciled: Bool
    ) -> LocalizedStringKey {
        if isSearching || statusFilter != .all {
            return "No matching transactions"
        }
        if hideCleared {
            return "No uncleared transactions"
        }
        if hideReconciled {
            return "No unreconciled transactions"
        }
        return "No transactions"
    }

    /// Pure so the note visibility rule can be covered without constructing a
    /// view. Search still suppresses the note even when the user preference
    /// allows it, because account search is scoped to transactions.
    nonisolated static func showsNote(
        supported: Bool,
        hidden: Bool,
        isSearching: Bool
    ) -> Bool {
        supported && !hidden && !isSearching
    }

    /// Pure so the credit-detail visibility rule can be covered without
    /// constructing a view.
    nonisolated static func showsCreditHeadroom(
        showingBreakdown: Bool,
        hasHeadroom: Bool
    ) -> Bool {
        showingBreakdown && hasHeadroom
    }

    /// The pager is created on first use rather than in init because its
    /// fetch closure needs the environment store, which isn't available
    /// until body/task time. Rebuilt when the account changes: the closure
    /// captures the id, so a reused pager would keep paging the old account.
    private func currentPager() -> TransactionPager {
        if let pager, pagerAccountId == account.id {
            return pager
        }
        let store = budgetStore
        let accountId = account.id
        let created = TransactionPager { offset, limit, search in
            await store.fetchTransactions(
                accountId: accountId, limit: limit, offset: offset, search: search,
                statusFilter: store.transactionStatusFilter,
                unclearedOnly: store.hideClearedTransactions,
                hideReconciled: store.hideReconciledTransactions
            )
        }
        pager = created
        pagerAccountId = accountId
        return created
    }

    private func reload() async {
        let fullHistory = searchQuery == nil
            && budgetStore.transactionStatusFilter == .all
            && !budgetStore.hideClearedTransactions
            && !budgetStore.hideReconciledTransactions
        loadedFullHistory = false
        breakdown = await budgetStore.balanceBreakdown(accountId: account.id)
        await reloadNote()
        await reloadCycleSpend()
        await reloadRecentStatements()
        await currentPager().loadFirstPage(search: searchQuery)
        loadedFullHistory = fullHistory
    }

    private func reloadRecentStatements() async {
        recentStatements = await budgetStore.fetchRecentStatements(accountId: account.id)
    }

    private func reloadCycleSpend() async {
        guard let cycle = budgetStore.activeCreditCardCycle(for: account.id) else {
            cycleSpend = 0
            return
        }
        let range = cycle.cycleRange()
        cycleSpend = await budgetStore.fetchCycleSpend(
            accountId: account.id,
            start: range.start,
            end: range.end
        )
    }

    private func reloadNote() async {
        note = await budgetStore.fetchNote(id: EntityNote.accountNoteId(account.id))
    }

    /// Fire the category-funding automation only for a newly-created manual
    /// standard expense. The callback carries the exact saved row id, so
    /// backdated entries and transactions in other accounts cannot be mixed up.
    private func handleManualTransactionSaved(_ savedTransactionId: String?) {
        CategoryFundingAutomation.processIfNeeded(savedTransactionId, using: budgetStore)
    }

    /// The account's note (GH #198), presented exactly as a category's is (see
    /// CategoryTransactionsView): visible without digging, tap to edit. Hidden
    /// while searching — a search is about finding transactions, not reading
    /// guidance — and on files with no `notes` table, where an edit could never
    /// save.
    private var noteSection: some View {
        Section(String(localized: "common.note")) {
            if note.isEmpty {
                Button {
                    editingNote = true
                } label: {
                    // Tinted: an empty note row is an invitation to act, where
                    // an existing note is content to read.
                    Label(String(localized: "common.addNote"), systemImage: "note.text.badge.plus")
                        .foregroundStyle(Color.accentColor)
                }
                // Plain: a tinted List button would tint the label twice over.
                .buttonStyle(.plain)
                .accessibilityIdentifier("accountNoteRow")
            } else {
                HStack(alignment: .top, spacing: 12) {
                    // Attributed so markdown links and bare URLs in the note
                    // are tappable (GH #190). That's also why this row is a
                    // tap gesture rather than the Button the empty state uses:
                    // a Button label swallows link taps, where links inside a
                    // gesture-carrying row take precedence over the gesture.
                    Text(NoteLinkText.attributed(note.text))
                        .multilineTextAlignment(.leading)
                        // Multi-line notes are the point — let the row grow
                        // instead of truncating the guidance to one line.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "pencil")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { editingNote = true }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("accountNoteRow")
            }
        }
    }

    private func breakdownRow(_ title: String, amount: Int) -> some View {
        breakdownRow(title, value: budgetStore.displayBalance(amount))
    }

    private func breakdownRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .animatedAmount(value)
        }
        .font(.subheadline)
    }

    /// One row of the account's transaction list, built outside `body` so the
    /// view expression stays within the type checker's budget.
    private func transactionRow(_ transaction: Transaction, showDate: Bool = true) -> some View {
        TransactionListRow(
            transaction: transaction,
            showAccount: false,
            showDate: showDate,
            isSelectionMode: $isSelecting,
            isSelected: selectedTransactionIds.contains(transaction.id),
            editing: $editingTransaction,
            onToggleSelect: {
                selectedTransactionIds.formSymmetricDifference([transaction.id])
            }
        )
    }

    private func balanceColumn(
        _ title: String,
        cents: Int?,
        alignment: HorizontalAlignment,
        identifier: String
    ) -> some View {
        let value = cents.map(budgetStore.displayBalance) ?? "—"
        return VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(.caption)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .animatedAmount(value)
        }
        .frame(
            maxWidth: .infinity,
            alignment: alignment == .leading ? .leading : .trailing
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var balanceHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            balanceColumn(
                String(localized: "Cleared"),
                cents: breakdown?.cleared,
                alignment: .leading,
                identifier: "accountBalance.cleared"
            )

            VStack(alignment: .center, spacing: 2) {
                Button {
                    withAnimation(AppAnimation.disclosure) { showingBreakdown.toggle() }
                } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            Text(String(localized: "Balance"))
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(showingBreakdown ? 180 : 0))
                                .opacity(breakdown == nil ? 0 : 1)
                        }
                        Text(budgetStore.displayBalance(currentBalance))
                            .font(.headline)
                            .foregroundStyle(balanceColor(for: currentBalance))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .animatedAmount(budgetStore.displayBalance(currentBalance))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("accountBalance.toggle")
                .accessibilityLabel(String(format: String(localized: "Current Balance, %@"), budgetStore.displayBalance(currentBalance)))
                .accessibilityHint(showingBreakdown
                    ? String(localized: "Hides the balance breakdown")
                    : String(localized: "Shows cleared, uncleared, and reconciled balances"))
                .disabled(breakdown == nil)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            balanceColumn(
                String(localized: "Uncleared"),
                cents: breakdown?.uncleared,
                alignment: .trailing,
                identifier: "accountBalance.uncleared"
            )
        }
    }

    private var balanceSection: some View {
        Section {
            balanceHeader

            if showingBreakdown, let breakdown {
                breakdownRow(String(localized: "Reconciled"), amount: breakdown.reconciled)
            }

            let headroom = creditHeadroom
            if Self.showsCreditHeadroom(
                showingBreakdown: showingBreakdown,
                hasHeadroom: headroom != nil
            ), let headroom {
                breakdownRow(String(localized: "Available Credit"), amount: headroom.available)
                breakdownRow(String(localized: "Credit Limit"), amount: headroom.limit)
            }
        }
    }

    @ViewBuilder private var billingCycleSection: some View {
        if let cycle = budgetStore.activeCreditCardCycle(for: account.id), searchQuery == nil {
            Section {
                let range = cycle.cycleRange()
                let startStr = Transaction.formattedDate(from: range.start.yyyymmdd, style: .abbreviated)
                let endStr = Transaction.formattedDate(from: range.end.yyyymmdd, style: .abbreviated)
                let dueSummary = cycle.dueSummary(dueDate: statementDue?.dueDate)

                // Collapsed by default like the balance breakdown above, but
                // the due date rides on the header row rather than hiding —
                // it's the part of this section worth acting on.
                Button {
                    withAnimation(AppAnimation.disclosure) { showingBillingCycle.toggle() }
                } label: {
                    HStack {
                        Text(String(localized: "Billing Cycle"))
                        Spacer()
                        Text(dueSummary)
                            .fontWeight(.semibold)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showingBillingCycle ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: String(localized: "Billing Cycle, %@"), dueSummary))
                .accessibilityHint(showingBillingCycle
                    ? String(localized: "Hides the billing cycle details")
                    : String(localized: "Shows the current cycle dates and spend"))

                if showingBillingCycle {
                    breakdownRow(String(localized: "Current Cycle"), value: "\(startStr) – \(endStr)")
                    if let statementDue {
                        if statementDue.isPaid {
                            breakdownRow(String(localized: "Statement Due"), value: String(localized: "Paid"))
                        } else {
                            breakdownRow(String(localized: "Statement Due"), value: budgetStore.displayBalance(statementDue.remainingDue))
                        }
                    }
                    breakdownRow(String(localized: "Cycle Spend"), value: budgetStore.displayBalance(cycleSpend))

                    if !recentStatements.isEmpty {
                        Divider()
                        ForEach(recentStatements) { statement in
                            let sStartStr = Transaction.formattedDate(from: statement.startDate.yyyymmdd, style: .abbreviated)
                            let sEndStr = Transaction.formattedDate(from: statement.endDate.yyyymmdd, style: .abbreviated)
                            Button {
                                selectedStatement = statement
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(sStartStr) – \(sEndStr)")
                                            .foregroundStyle(.primary)
                                        if statement.isPaid {
                                            Text(String(localized: "Paid"))
                                                .font(.caption)
                                                .foregroundStyle(.green)
                                        } else {
                                            let dueStr = Transaction.formattedDate(from: statement.dueDate.yyyymmdd, style: .abbreviated)
                                            Text(String(format: String(localized: "Due %@"), dueStr))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(budgetStore.displayBalance(statement.statementBalance))
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(format: String(localized: "Statement %1$@ to %2$@, %3$@"), sStartStr, sEndStr, budgetStore.displayBalance(statement.statementBalance)))
                        }
                    }
                }
            }
        }
    }

    /// Payoff tracking for an account marked as a loan. Collapsed by default
    /// like the billing cycle above, with the payoff date riding on the header
    /// row — that's the part worth acting on. Read-only: the terms are edited
    /// on the Loans screen.
    @ViewBuilder private var loanSection: some View {
        if let config = budgetStore.activeLoanConfig(for: account.id), searchQuery == nil {
            Section {
                let summary = config.payoffSummary(accountBalance: currentBalance)
                let fraction = config.fractionPaidOff(accountBalance: currentBalance)

                Button {
                    withAnimation(AppAnimation.disclosure) { showingLoanDetails.toggle() }
                } label: {
                    VStack(spacing: 6) {
                        HStack {
                            Text(String(localized: "Loan"))
                            Spacer()
                            Text(summary)
                                .fontWeight(.semibold)
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(showingLoanDetails ? 180 : 0))
                        }
                        ProgressView(value: fraction)
                            .tint(.accentColor)
                        HStack {
                            Text(LoanSummaryRow.progressText(fraction))
                            Spacer()
                            Text(String(format: String(localized: "of %@"), budgetStore.displayBalance(config.originalBalance)))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("accountLoan.toggle")
                .accessibilityLabel(String(format: String(localized: "Loan, %1$@, %2$@"), LoanSummaryRow.progressText(fraction), summary))
                .accessibilityHint(showingLoanDetails
                    ? String(localized: "Hides the loan details")
                    : String(localized: "Shows the loan's rate, payment and remaining interest"))

                if showingLoanDetails {
                    breakdownRow(String(localized: "Original Balance"), amount: config.originalBalance)
                    breakdownRow(String(localized: "Interest Rate"), value: LoanSummaryRow.percentText(config.annualRatePercent / 100))
                    breakdownRow(String(localized: "Monthly Payment"), amount: config.minimumPayment)
                    if let escrow = config.escrowOrFees {
                        breakdownRow(String(localized: "Escrow or Fees"), amount: escrow)
                    }
                    if let schedule = config.schedule(accountBalance: currentBalance) {
                        breakdownRow(String(localized: "Payments Remaining"), value: "\(schedule.paymentCount)")
                        breakdownRow(String(localized: "Interest Remaining"), amount: schedule.totalInterest)
                    }

                    // The terms are most often questioned while looking at the
                    // loan itself, so the editor opens from here rather than
                    // sending the user back out to the Loans screen.
                    Button {
                        showingLoanEditor = true
                    } label: {
                        Label(String(localized: "Edit Loan"), systemImage: "pencil")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(budgetStore.syncDetachedByRestore)
                    .accessibilityIdentifier("accountLoan.edit")
                }
            }
        }
    }

    @ViewBuilder private var notesSection: some View {
        if Self.showsNote(
            supported: note.supported,
            hidden: hideNotes,
            isSearching: searchQuery != nil
        ) {
            noteSection
        }
    }

    @ViewBuilder private var transactionSection: some View {
        if let pager, !pager.transactions.isEmpty {
            let displayedTransactions = transactionsForDisplay
            if budgetStore.transactionDisplayMode == .groupedByDate {
                let groups = displayedTransactions.groupedByDate()
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.transactions) { transaction in
                            transactionRow(transaction, showDate: false)
                        }
                        // The sentinel rides in the last date section so
                        // grouped mode doesn't grow a headerless section
                        // (and its gap) of its own.
                        if pager.hasMore, group.id == groups.last?.id {
                            TransactionPagingSentinel(pager: pager)
                        }
                    }
                }
            } else {
                Section("Recent Transactions") {
                    ForEach(displayedTransactions) { transaction in
                        transactionRow(transaction)
                    }
                    if pager.hasMore {
                        TransactionPagingSentinel(pager: pager)
                    }
                }
            }
        } else {
            // Header stays put while the first page is still loading, so
            // the screen doesn't reflow once the rows land.
            Section("Recent Transactions") {
                if pager != nil {
                    Text(emptyTransactionsText)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var runningBalanceToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .secondaryAction) {
            Toggle(isOn: $showRunningBalance) {
                Label(
                    "Show Running Balance",
                    systemImage: showRunningBalance ? "eye" : "eye.slash"
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var accountToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if isSelecting {
                Button("Done") {
                    withAnimation {
                        isSelecting = false
                        selectedTransactionIds.removeAll()
                    }
                }
            } else {
                Button {
                    showingAddTransaction = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Transaction")
            }
        }
        if !isSelecting {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    withAnimation { isSelecting = true }
                } label: {
                    Label("Select Transactions", systemImage: "checkmark.circle")
                }
            }
        }
        if WalletImportView.isSupported {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingWalletImport = true
                } label: {
                    Label("Import from Wallet", systemImage: "wallet.pass")
                }
            }
        }
        if budgetStore.bankSyncAccount(forAccountId: account.id) != nil {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    Task { await budgetStore.runBankSync(accountIds: [account.id]) }
                } label: {
                    Label("Sync from Bank", systemImage: "building.columns")
                }
                .disabled(budgetStore.isBankSyncing)
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Toggle(isOn: $budgetStore.showTransactionStatusFilters) {
                Label("Status Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            TransactionGroupingToggle()
        }
        ToolbarItem(placement: .secondaryAction) {
            Toggle(isOn: $budgetStore.hideClearedTransactions) {
                Label(
                    "Hide Cleared Transactions",
                    systemImage: budgetStore.hideClearedTransactions ? "eye.slash" : "eye"
                )
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Toggle(isOn: $budgetStore.hideReconciledTransactions) {
                Label(
                    "Hide Reconciled Transactions",
                    systemImage: budgetStore.hideReconciledTransactions ? "eye.slash" : "eye"
                )
            }
        }

        if note.supported {
            ToolbarItem(placement: .secondaryAction) {
                Toggle(isOn: $hideNotes) {
                    Label(
                        "Hide Notes",
                        systemImage: hideNotes ? "eye.slash" : "eye"
                    )
                }
                .accessibilityIdentifier("accountDetails.notesVisibility")
            }
        }

        ToolbarItem(placement: .secondaryAction) {
            Button {
                showingReconcile = true
            } label: {
                Label("Reconcile", systemImage: "lock.fill")
            }
        }
    }

    var body: some View {
        List {
            balanceSection
            billingCycleSection
            loanSection
            notesSection.animation(AppAnimation.disclosure, value: hideNotes)
            transactionSection
        }
        .contentMargins(.horizontal, 6, for: .scrollContent)
        // The header sections (balance, billing cycle, note) are one or two rows
        // each, so the stock inset-grouped gaps pushed the transactions off
        // screen. Tighter spacing top and between.
        .contentMargins(.top, 8, for: .scrollContent)
        .listSectionSpacing(.compact)
        .readableWidth()
        .navigationTitle(account.name)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search transactions")
        .toolbar {
            accountToolbarContent
            runningBalanceToolbarItem
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting, let pager {
                TransactionBulkActionBar(
                    transactions: pager.transactions,
                    selectedIds: $selectedTransactionIds,
                    isSelecting: $isSelecting
                )
            }
        }
        .toolbar(isSelecting ? .hidden : .visible, for: .tabBar)
        .sheet(isPresented: $showingLoanEditor) {
            // Read at presentation rather than captured with the button, so
            // the editor opens on the current terms even if a sync landed
            // between the tap and the sheet.
            if let config = budgetStore.activeLoanConfig(for: account.id) {
                LoanEditorView(mode: .edit(accountId: account.id, config: config))
                    .environmentObject(budgetStore)
            }
        }
        .sheet(isPresented: $showingReconcile) {
            ReconcileView(account: account)
                .environmentObject(budgetStore)
        }
        .sheet(isPresented: $showingWalletImport) {
            WalletImportView(preselectedAccountId: account.id)
                .environmentObject(budgetStore)
        }
        .sheet(isPresented: $showingAddTransaction) {
            AddTransactionView(
                accountId: account.id,
                onSaved: handleManualTransactionSaved
            )
            .environmentObject(budgetStore)
        }
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionView(editing: transaction)
                .environmentObject(budgetStore)
        }
        .sheet(isPresented: $editingNote, onDismiss: {
            // Only the note needs re-reading — a note save doesn't touch
            // transactions or the balance.
            Task { await reloadNote() }
        }) {
            NoteEditorView(
                noteId: EntityNote.accountNoteId(account.id),
                title: account.name,
                note: note.text
            )
            .environmentObject(budgetStore)
        }
        .sheet(item: $selectedStatement) { statement in
            CreditCardStatementDetailView(account: account, statement: statement)
                .environmentObject(budgetStore)
        }
        // Keyed on the account as well as the search: selecting another
        // account in the iPad split layout reuses this view, and without the
        // account in the key nothing would reload — the previous account's
        // rows would sit under the new one's name and balance.
        .task(id: [account.id, searchText]) {
            loadedFullHistory = false
            if pagerAccountId != account.id {
                // Drop the previous account's page and balance split rather
                // than showing them while the new ones load — and its
                // selection state, which was scoped to its rows.
                pager = nil
                breakdown = nil
                showingBreakdown = false
                cycleSpend = 0
                recentStatements = []
                isSelecting = false
                selectedTransactionIds.removeAll()
            } else if searchQuery != nil {
                // Debounce keystrokes; the initial (empty) load and account
                // switches run immediately.
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled {
                    return
                }
            }
            await reload()
        }
        .onChange(of: budgetStore.dataVersion) {
            // The store republished its data — refresh the cached page. This
            // is the single reload path for every mutation (row toggles,
            // deletes, sheet edits, sync, scheduled posts), so those sites
            // carry no reload calls of their own. Concurrent reloads are
            // safe: the pager's generation counter keeps the newest.
            Task { await reload() }
        }
        .onChange(of: budgetStore.hideClearedTransactions) {
            // The pager's fetch closure reads the flag, so a reload is all a
            // toggle flip needs.
            loadedFullHistory = false
            Task { await reload() }
        }
        .onChange(of: budgetStore.hideReconciledTransactions) {
            loadedFullHistory = false
            Task { await reload() }
        }
        .onChange(of: budgetStore.transactionStatusFilter) {
            // The pager's fetch closure reads the chip, so a reload is all a
            // chip tap needs.
            Task { await reload() }
        }
        .onChange(of: budgetStore.creditCardStatementDays[account.id]) {
            Task {
                await reloadCycleSpend()
                await reloadRecentStatements()
            }
        }
        .refreshable {
            await budgetStore.sync()
            await reload()
        }
    }
}

#Preview {
    NavigationStack {
        AccountDetailView(
            account: Account(
                id: "1",
                name: "Checking",
                type: .checking,
                offBudget: false,
                closed: false,
                sortOrder: 0,
                balance: 245_073
            )
        )
        .environmentObject(BudgetStore.previewInstance())
    }
}
