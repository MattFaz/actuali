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
    @State private var searchText = ""
    @State private var showingAddTransaction = false
    @State private var showingReconcile = false
    @State private var showingWalletImport = false
    @State private var editingTransaction: Transaction?
    /// The account's note (GH #198). Starts `.unsupported` so the menu item
    /// stays hidden until the read confirms this file can store notes.
    @State private var note: EntityNote = .unsupported
    @State private var editingNote = false

    private var currentBalance: Int {
        budgetStore.accounts.first { $0.id == account.id }?.balance ?? account.balance
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
        await currentPager().loadFirstPage(search: searchQuery)
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
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(budgetStore.displayBalance(amount))
                .foregroundStyle(.secondary)
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
                    withAnimation { showingBreakdown.toggle() }
                } label: {
                    HStack {
                        Text("Current Balance")
                        Spacer()
                        Text(budgetStore.displayBalance(currentBalance))
                            .fontWeight(.semibold)
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

                if showingBreakdown, let breakdown {
                    breakdownRow("Cleared", amount: breakdown.cleared)
                    breakdownRow("Uncleared", amount: breakdown.uncleared)
                    breakdownRow("Reconciled", amount: breakdown.reconciled)
                }
            }

            if note.supported && searchQuery == nil {
                noteSection
            }

            Section("Recent Transactions") {
                if let pager, pager.transactions.isEmpty {
                    Text(searchQuery != nil
                        ? "No matching transactions"
                        : budgetStore.hideClearedTransactions
                            ? "No uncleared transactions"
                            : "No transactions")
                        .foregroundStyle(.secondary)
                } else if let pager {
                    ForEach(pager.transactions) { transaction in
                        Button {
                            editingTransaction = transaction
                        } label: {
                            TransactionRow(transaction: transaction, showAccount: false, onToggleCleared: {
                                Task { await budgetStore.toggleCleared(transaction) }
                            })
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await budgetStore.deleteTransaction(transaction) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                editingTransaction = transaction
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.yellow)
                        }
                    }
                    if pager.hasMore {
                        // Sentinel row: appearing near the bottom of the list
                        // pulls in the next page.
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .task { await pager.loadNextPage() }
                    }
                }
            }
        }
        .contentMargins(.horizontal, 6, for: .scrollContent)
        .readableWidth()
        .navigationTitle(account.name)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search transactions")
        .toolbar {
            if WalletImportView.isSupported {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showingWalletImport = true
                    } label: {
                        Label("Import from Wallet", systemImage: "wallet.pass")
                    }
                }
            }
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddTransaction = true
                } label: {
                    Image(systemName: "plus")
                }
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
                // than showing them while the new ones load.
                pager = nil
                breakdown = nil
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
