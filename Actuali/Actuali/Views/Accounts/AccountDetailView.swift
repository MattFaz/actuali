import SwiftUI

struct AccountDetailView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let account: Account

    @State private var pager: TransactionPager?
    @State private var pagerAccountId: String?
    @State private var breakdown: AccountBalanceBreakdown?
    @State private var showingBreakdown = false
    @State private var showingBillingCycle = false
    @State private var searchText = ""
    @State private var showingAddTransaction = false
    @State private var showingReconcile = false
    @State private var showingWalletImport = false
    @State private var editingTransaction: Transaction?
    @State private var note: EntityNote = .unsupported
    @State private var editingNote = false
    @State private var isSelecting = false
    @State private var selectedTransactionIds: Set<String> = []
    @State private var cycleSpend: Int = 0

    private var currentBalance: Int {
        budgetStore.accounts.first { $0.id == account.id }?.balance ?? account.balance
    }

    private var creditHeadroom: (limit: Int, available: Int)? {
        guard let available = budgetStore.availableCredit(for: account.id),
              let limit = budgetStore.creditCardLimits[account.id] else { return nil }
        return (limit, available)
    }

    private var searchQuery: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

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

    private func breakdownRow(_ title: String, amount: Int) -> some View {
        breakdownRow(title, value: budgetStore.displayBalance(amount))
    }

    private func breakdownRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.secondary).animatedAmount(value)
        }
        .font(.subheadline)
    }

    var body: some View {
        List {
            Section {
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

                    Button {
                        withAnimation(AppAnimation.disclosure) { showingBillingCycle.toggle() }
                    } label: {
                        HStack {
                            Text("Billing Cycle")
                            Spacer()
                            Text(dueSummary).fontWeight(.semibold)
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
            ToolbarItem(placement: .secondaryAction) { TransactionGroupingToggle() }
            ToolbarItem(placement: .secondaryAction) {
                Toggle("Hide Cleared Transactions", isOn: $budgetStore.hideClearedTransactions)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingReconcile = true
                } label: {
                    Label("Reconcile", systemImage: "checkmark.seal")
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
            ReconcileView(account: account).environmentObject(budgetStore)
        }
        .sheet(isPresented: $showingWalletImport) {
            WalletImportView(preselectedAccountId: account.id).environmentObject(budgetStore)
        }
        .sheet(isPresented: $showingAddTransaction) {
            AddTransactionView(
                accountId: account.id,
                onSaved: {
                    Task { @MainActor in
                        await CategoryFundingAutomation.processLatestManualTransaction(using: budgetStore)
                    }
                }
            )
            .environmentObject(budgetStore)
        }
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionView(editing: transaction).environmentObject(budgetStore)
        }
        .sheet(isPresented: $editingNote, onDismiss: {
            Task { await reloadNote() }
        }) {
            NoteEditorView(
                noteId: EntityNote.accountNoteId(account.id),
                title: account.name,
                note: note.text
            )
            .environmentObject(budgetStore)
        }
        .task(id: [account.id, searchText]) {
            if pagerAccountId != account.id {
                pager = nil
                breakdown = nil
                cycleSpend = 0
                isSelecting = false
                selectedTransactionIds.removeAll()
            } else if searchQuery != nil {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            await reload()
        }
        .onChange(of: budgetStore.dataVersion) {
            Task { await reload() }
        }
        .onChange(of: budgetStore.hideClearedTransactions) {
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
