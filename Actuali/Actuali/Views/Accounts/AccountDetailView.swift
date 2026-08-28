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
    @State private var searchText = ""
    @State private var showingAddTransaction = false
    @State private var showingReconcile = false
    @State private var showingWalletImport = false
    @State private var editingTransaction: Transaction?
    /// The account's note (GH #198). Starts `.unsupported` so the menu item
    /// stays hidden until the read confirms this file can store notes.
    @State private var note: EntityNote = .unsupported
    @State private var editingNote = false
    @State private var isSelecting = false
    @State private var selectedTransactionIds: Set<String> = []
    @State private var cycleSpend: Int = 0

    private var currentBalance: Int {
        budgetStore.accounts.first { $0.id == account.id }?.balance ?? account.balance
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

    /// The pager is created on first use rather than in init because its
    /// fetch closure needs the environment store, which isn't available
    /// until body/task time. Rebuilt when the account changes: the closure
    /// captures the id, so a reused pager would keep paging the old account.
    private func currentPager() -> TransactionPager {
        if let pager, pagerAccountId == account.id { return pager }
        let store = budgetStore
        let accountId = account.id
        let created = TransactionPager { offset, limit, search in
            await store.fetchTransactions(
                accountId: accountId, limit: limit, offset: offset, search: search,
                unclearedOnly: store.hideClearedTransactions
            )
        }
        pager = created
        pagerAccountId = accountId
        return created
    }

    private func reload() async {
        breakdown = await budgetStore.balanceBreakdown(accountId: account.id)
        await reloadNote()
        await reloadCycleSpend()
        await currentPager().loadFirstPage(search: searchQuery)
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

    /// The account's note (GH #198), presented exactly as a category's is (see
    /// CategoryTransactionsView): visible without digging, tap to edit. Hidden
    /// while searching — a search is about finding transactions, not reading
    /// guidance — and on files with no `notes` table, where an edit could never
    /// save.
    private var noteSection: some View {
        Section("Note") {
            if note.isEmpty {
                Button {
                    editingNote = true
                } label: {
                    // Tinted: an empty note row is an invitation to act, where
                    // an existing note is content to read.
                    Label("Add Note", systemImage: "note.text.badge.plus")
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

    var body: some View {
        List {
            Section {
                // Tapping the balance reveals the cleared/uncleared/reconciled
                // split (GH #134), so the reconciled figure can be checked
                // against a bank statement without starting a reconciliation.
                Button {
                    withAnimation(AppAnimation.disclosure) { showingBreakdown.toggle() }
                } label: {
                    HStack {
                        Text("Current Balance")
                        Spacer()
                        Text(budgetStore.displayBalance(currentBalance))
                            .fontWeight(.semibold)
                            .animatedAmount(budgetStore.displayBalance(currentBalance)) 
                        if breakdown != nil {
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(showingBreakdown ? 180 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Current Balance, \(budgetStore.displayBalance(currentBalance))")
                .accessibilityHint(showingBreakdown ? "Hides the balance breakdown" : "Shows cleared, uncleared, and reconciled balances")

                // Headroom on a tracked card with a limit set — the figure a
                // card's balance is actually judged against, so it stays visible
                // rather than hiding behind the disclosure.
                if let headroom = creditHeadroom {
                    breakdownRow("Available Credit", amount: headroom.available)
                }

                if showingBreakdown, let breakdown {
                    breakdownRow("Cleared", amount: breakdown.cleared)
                    breakdownRow("Uncleared", amount: breakdown.uncleared)
                    breakdownRow("Reconciled", amount: breakdown.reconciled)
                    if let headroom = creditHeadroom {
                        breakdownRow("Credit Limit", amount: headroom.limit)
                    }
                }
            }

            if let cycle = budgetStore.activeCreditCardCycle(for: account.id), searchQuery == nil {
                Section {
                    let range = cycle.cycleRange()
                    let startStr = Transaction.formattedDate(from: range.start.yyyymmdd, style: .abbreviated)
                    let endStr = Transaction.formattedDate(from: range.end.yyyymmdd, style: .abbreviated)
                    let dueSummary = cycle.dueSummary()

                    // Collapsed by default like the balance breakdown above, but
                    // the due date rides on the header row rather than hiding —
                    // it's the part of this section worth acting on.
                    Button {
                        withAnimation(AppAnimation.disclosure) { showingBillingCycle.toggle() }
                    } label: {
                        HStack {
                            Text("Billing Cycle")
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
                    .accessibilityLabel("Billing Cycle, \(dueSummary)")
                    .accessibilityHint(showingBillingCycle ? "Hides the billing cycle details" : "Shows the current cycle dates and spend")

                    if showingBillingCycle {
                        breakdownRow("Current Cycle", value: "\(startStr) – \(endStr)")
                        breakdownRow("Cycle Spend", value: budgetStore.displayBalance(cycleSpend))
                    }
                }
            }

            if note.supported && searchQuery == nil {
                noteSection
            }

            if let pager, !pager.transactions.isEmpty {
                if budgetStore.transactionDisplayMode == .groupedByDate {
                    let groups = pager.transactions.groupedByDate()
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.transactions) { transaction in
                                TransactionListRow(
                                    transaction: transaction,
                                    showAccount: false,
                                    showDate: false,
                                    isSelectionMode: isSelecting,
                                    isSelected: selectedTransactionIds.contains(transaction.id),
                                    editing: $editingTransaction,
                                    onToggleSelect: {
                                        selectedTransactionIds.formSymmetricDifference([transaction.id])
                                    }
                                )
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
                        ForEach(pager.transactions) { transaction in
                            TransactionListRow(
                                transaction: transaction,
                                showAccount: false,
                                isSelectionMode: isSelecting,
                                isSelected: selectedTransactionIds.contains(transaction.id),
                                editing: $editingTransaction,
                                onToggleSelect: {
                                    selectedTransactionIds.formSymmetricDifference([transaction.id])
                                }
                            )
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
                        Text(searchQuery != nil
                            ? "No matching transactions"
                            : budgetStore.hideClearedTransactions
                                ? "No uncleared transactions"
                                : "No transactions")
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
                TransactionGroupingToggle()
            }
           ToolbarItem(placement: .secondaryAction) {
                Button {
                    withAnimation { budgetStore.hideClearedTransactions.toggle() }
                } label: {
                    Label(
                        "Hide Cleared Transactions",
                        systemImage: budgetStore.hideClearedTransactions ? "eye.slash" : "eye"
                    )
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
        .sheet(isPresented: $showingReconcile) {
            ReconcileView(account: account)
                .environmentObject(budgetStore)
        }
        .sheet(isPresented: $showingWalletImport) {
            WalletImportView(preselectedAccountId: account.id)
                .environmentObject(budgetStore)
        }
        .sheet(isPresented: $showingAddTransaction) {
            AddTransactionView(accountId: account.id)
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
        // Keyed on the account as well as the search: selecting another
        // account in the iPad split layout reuses this view, and without the
        // account in the key nothing would reload — the previous account's
        // rows would sit under the new one's name and balance.
        .task(id: [account.id, searchText]) {
            if pagerAccountId != account.id {
                // Drop the previous account's page and balance split rather
                // than showing them while the new ones load — and its
                // selection state, which was scoped to its rows.
                pager = nil
                breakdown = nil
                cycleSpend = 0
                isSelecting = false
                selectedTransactionIds.removeAll()
            } else if searchQuery != nil {
                // Debounce keystrokes; the initial (empty) load and account
                // switches run immediately.
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
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
            Task { await reload() }
        }
        .onChange(of: budgetStore.creditCardStatementDays[account.id]) {
            Task { await reloadCycleSpend() }
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
                balance: 245073
            )
        )
        .environmentObject(BudgetStore.previewInstance())
    }
}
