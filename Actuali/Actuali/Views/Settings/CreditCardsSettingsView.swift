import SwiftUI

/// View for managing credit card accounts and their monthly billing cycles.
struct CreditCardsSettingsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var showingAddSheet = false
    @State private var editingAccountId: String?
    @State private var selectedAccountId = ""
    @State private var selectedStatementDay = 15
    @State private var selectedDueOffset = CreditCardCycle.defaultDueOffsetDays
    /// Dot-decimal amount as typed, the format `AmountInputField` binds to.
    /// Empty means "no limit set".
    @State private var selectedLimitText = ""

    private var configuredCards: [(account: Account, cycle: CreditCardCycle)] {
        let accountsById = Dictionary(uniqueKeysWithValues: budgetStore.accounts.map { ($0.id, $0) })
        return Self.sortedCards(budgetStore.activeCreditCardStatementDays.compactMap { accountId, _ in
            guard let account = accountsById[accountId],
                  let cycle = budgetStore.creditCardCycle(for: accountId) else { return nil }
            return (account: account, cycle: cycle)
        })
    }

    /// Soonest payment first. The name tie-break is what makes this a total
    /// order: `daysUntilDue` clamps at 0, so every past-due card ties there, and
    /// the input arrives from a `Dictionary` whose order is reseeded per launch.
    /// `today` is sampled once rather than per comparison so the ordering can't
    /// change underneath `sorted` at midnight.
    nonisolated static func sortedCards(
        _ cards: [(account: Account, cycle: CreditCardCycle)],
        today: DayDate = .today()
    ) -> [(account: Account, cycle: CreditCardCycle)] {
        cards.sorted {
            ($0.cycle.daysUntilDue(for: today), $0.account.name)
                < ($1.cycle.daysUntilDue(for: today), $1.account.name)
        }
    }

    private var unconfiguredAccounts: [Account] {
        let configuredIds = Set(budgetStore.creditCardStatementDays.keys)
        return budgetStore.accounts
            .filter { !$0.closed && !configuredIds.contains($0.id) }
            .sorted { ($0.type == .credit ? 0 : 1, $0.name) < ($1.type == .credit ? 0 : 1, $1.name) }
    }

    var body: some View {
        List {
            Section("Configured Credit Cards") {
                if configuredCards.isEmpty {
                    Text("Mark accounts as credit cards and track their monthly billing cycles, cycle spend, and upcoming payment due dates.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    // Bound once so the delete closure indexes the exact array
                    // the rows were built from. The sort key is a day count, so
                    // recomputing it inside the closure could reorder the list
                    // out from under a swipe that started before midnight.
                    let cards = configuredCards
                    let detached = budgetStore.syncDetachedByRestore
                    ForEach(cards, id: \.account.id) { item in
                        Button {
                            selectedAccountId = item.account.id
                            selectedStatementDay = item.cycle.statementDay
                            selectedDueOffset = item.cycle.dueOffsetDays
                            selectedLimitText = limitText(for: item.account.id)
                            editingAccountId = item.account.id
                        } label: {
                            CreditCardCycleRow(account: item.account, cycle: item.cycle)
                        }
                        .buttonStyle(.plain)
                        .disabled(detached)
                        .listRowBackground(
                            CreditCardCycleRow.cardBackground(
                                daysUntilDue: item.cycle.daysUntilDue()
                            )
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    }
                    .onDelete { offsets in
                        for accountId in offsets.map({ cards[$0].account.id }) {
                            Task {
                                await budgetStore.setCreditCard(
                                    accountId: accountId,
                                    statementDay: nil,
                                    limit: nil
                                )
                            }
                        }
                    }
                    .deleteDisabled(detached)
                }
            }

            if budgetStore.syncDetachedByRestore {
                Section {
                    Text("Credit card settings sync with your budget. Re-download this budget to change them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if !unconfiguredAccounts.isEmpty {
                Section {
                    Button {
                        if let first = unconfiguredAccounts.first {
                            selectedAccountId = first.id
                        }
                        selectedStatementDay = 15
                        selectedDueOffset = CreditCardCycle.defaultDueOffsetDays
                        selectedLimitText = ""
                        showingAddSheet = true
                    } label: {
                        Label("Add Credit Card", systemImage: "plus")
                    }
                }
            }
        }
        .navigationTitle("Credit Cards")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddSheet) {
            cardSheet(isEditing: false)
        }
        .sheet(isPresented: Binding(
            get: { editingAccountId != nil },
            set: { if !$0 { editingAccountId = nil } }
        )) {
            cardSheet(isEditing: true)
        }
    }

    @ViewBuilder
    private func cardSheet(isEditing: Bool) -> some View {
        NavigationStack {
            Form {
                Section {
                    if isEditing {
                        if let account = budgetStore.accounts.first(where: { $0.id == selectedAccountId }) {
                            LabeledContent("Account", value: account.name)
                        }
                    } else {
                        Picker("Account", selection: $selectedAccountId) {
                            ForEach(unconfiguredAccounts) { account in
                                Text(account.name).tag(account.id)
                            }
                        }
                    }

                    Picker("Statement Closing Day", selection: $selectedStatementDay) {
                        ForEach(1...31, id: \.self) { day in
                            Text(dayOrdinal(day)).tag(day)
                        }
                    }

                    Picker("Payment Due After", selection: $selectedDueOffset) {
                        ForEach(1...CreditCardCycle.maxDueOffsetDays, id: \.self) { days in
                            Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                        }
                    }

                    HStack {
                        Text("Credit Limit")
                        Spacer()
                        AmountInputField(
                            text: $selectedLimitText,
                            conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                            alignment: .right
                        )
                    }
                } header: {
                    Text("Card Details")
                } footer: {
                    Text("The payment due date is the statement closing date plus this many days. Your issuer sets it — check a recent statement, as it varies by card and country.\n\nA credit limit shows available credit on the account. Leave it empty to skip.")
                }

                if isEditing {
                    Section {
                        Button("Remove Credit Card Tracking", role: .destructive) {
                            Task {
                                await budgetStore.setCreditCard(
                                    accountId: selectedAccountId,
                                    statementDay: nil,
                                    limit: nil
                                )
                            }
                            editingAccountId = nil
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Card" : "Add Credit Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingAddSheet = false
                        editingAccountId = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await budgetStore.setCreditCard(
                                accountId: selectedAccountId,
                                statementDay: selectedStatementDay,
                                dueOffsetDays: selectedDueOffset,
                                limit: enteredLimitCents
                            )
                        }
                        showingAddSheet = false
                        editingAccountId = nil
                    }
                    .disabled(selectedAccountId.isEmpty)
                }
            }
        }
    }

    /// nil for an empty, unparseable, or non-positive entry — all of which mean
    /// "no limit" rather than an error worth blocking the save on.
    private var enteredLimitCents: Int? {
        guard let dollars = AmountParser.parse(selectedLimitText),
              let cents = Transaction.cents(fromDollars: dollars),
              cents > 0 else { return nil }
        return cents
    }

    private func limitText(for accountId: String) -> String {
        guard let cents = budgetStore.creditCardLimits[accountId], cents != 0 else { return "" }
        return String(format: "%.2f", Double(cents) / 100.0)
    }

    private static let ordinalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter
    }()

    private func dayOrdinal(_ n: Int) -> String {
        Self.ordinalFormatter.string(from: NSNumber(value: n)) ?? "\(n)th"
    }
}

/// Compact card row: name + balance on top, spend + due pill on bottom.
/// The colored left border and card background are applied by the parent via
/// `listRowBackground` using `cardBackground(daysUntilDue:)`.
struct CreditCardCycleRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let account: Account
    let cycle: CreditCardCycle

    @State private var cycleSpend: Int = 0

    private var cycleRange: (start: DayDate, end: DayDate) {
        cycle.cycleRange()
    }

    /// Urgency color: red ≤3d, orange ≤7d, yellow otherwise. Used at full
    /// strength for the border strip and heavily faded behind the pill — the
    /// pill's own text stays `.primary`, because system yellow on a light
    /// background is about 1.4:1 and unreadable at caption size.
    nonisolated static func urgencyColor(days: Int) -> Color {
        if days <= 3 { return .red }
        if days <= 7 { return .orange }
        return .yellow
    }

    private var dueColor: Color {
        Self.urgencyColor(days: cycle.daysUntilDue())
    }

    /// Card background with a colored left urgency border strip.
    nonisolated static func cardBackground(daysUntilDue days: Int) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(.secondarySystemGroupedBackground))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(
                    topLeadingRadius: 10, bottomLeadingRadius: 10,
                    bottomTrailingRadius: 0, topTrailingRadius: 0
                )
                .fill(urgencyColor(days: days))
                .frame(width: 3)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Row 1: name + balance
            HStack(alignment: .firstTextBaseline) {
                Text(account.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(budgetStore.displayBalance(account.balance))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(balanceColor(for: account.balance))
            }

            // Row 2: cycle spend + days left + due pill
            HStack {
                Text("Spend \(budgetStore.displayBalance(cycleSpend)) · \(cycle.daysRemainingInCycle())d left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(cycle.dueShortSummary())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(dueColor.opacity(0.22), in: .capsule)
                    // The pill is the actionable half of this line, so the
                    // spend text takes the squeeze at large Dynamic Type sizes.
                    .fixedSize()
            }
        }
        .padding(.vertical, 2)
        // One element per card, worded like AccountDetailView's billing cycle
        // header — the long `dueSummary` carries the date the pill drops.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(account.name), balance \(budgetStore.displayBalance(account.balance)), "
                + "cycle spend \(budgetStore.displayBalance(cycleSpend)), \(cycle.dueSummary())"
        )
        // dataVersion is in the key so a transaction landing while this screen
        // is open refreshes the spend, the way AccountDetailView's reload does.
        .task(id: [cycle.statementDay, budgetStore.dataVersion]) {
            cycleSpend = await budgetStore.fetchCycleSpend(
                accountId: account.id,
                start: cycleRange.start,
                end: cycleRange.end
            )
        }
    }
}

#Preview {
    NavigationStack {
        CreditCardsSettingsView()
            .environmentObject(BudgetStore.previewInstance())
    }
}
