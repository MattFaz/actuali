import SwiftUI

/// View for managing credit card accounts and their monthly billing cycles.
struct CreditCardsSettingsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var showingAddSheet = false
    @State private var editingAccountId: String?
    @State private var selectedAccountId = ""
    @State private var selectedStatementDay = 15
    @State private var selectedDueOffset = CreditCardCycle.defaultDueOffsetDays

    private var configuredCards: [(account: Account, cycle: CreditCardCycle)] {
        let accountsById = Dictionary(uniqueKeysWithValues: budgetStore.accounts.map { ($0.id, $0) })
        return budgetStore.activeCreditCardStatementDays.compactMap { accountId, _ in
            guard let account = accountsById[accountId],
                  let cycle = budgetStore.creditCardCycle(for: accountId) else { return nil }
            return (account: account, cycle: cycle)
        }.sorted { $0.account.name < $1.account.name }
    }

    private var unconfiguredAccounts: [Account] {
        let configuredIds = Set(budgetStore.creditCardStatementDays.keys)
        return budgetStore.accounts
            .filter { !$0.closed && !configuredIds.contains($0.id) }
            .sorted { ($0.type == .credit ? 0 : 1, $0.name) < ($1.type == .credit ? 0 : 1, $1.name) }
    }

    var body: some View {
        List {
            Section {
                Text("Mark accounts as credit cards and track their monthly billing cycles, cycle spend, and upcoming payment due dates.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Configured Credit Cards") {
                if configuredCards.isEmpty {
                    Text("No credit cards configured yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(configuredCards, id: \.account.id) { item in
                        Button {
                            selectedAccountId = item.account.id
                            selectedStatementDay = item.cycle.statementDay
                            selectedDueOffset = item.cycle.dueOffsetDays
                            editingAccountId = item.account.id
                        } label: {
                            CreditCardCycleRow(account: item.account, cycle: item.cycle)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteCard)
                }
            }

            if !unconfiguredAccounts.isEmpty {
                Section {
                    Button {
                        if let first = unconfiguredAccounts.first {
                            selectedAccountId = first.id
                        }
                        selectedStatementDay = 15
                        selectedDueOffset = CreditCardCycle.defaultDueOffsetDays
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

    private func deleteCard(at offsets: IndexSet) {
        let cards = configuredCards
        for accountId in offsets.map({ cards[$0].account.id }) {
            budgetStore.setCreditCard(accountId: accountId, statementDay: nil)
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
                } header: {
                    Text("Card Details")
                } footer: {
                    Text("The payment due date is the statement closing date plus this many days. Your issuer sets it — check a recent statement, as it varies by card and country.")
                }

                if isEditing {
                    Section {
                        Button("Remove Credit Card Tracking", role: .destructive) {
                            budgetStore.setCreditCard(accountId: selectedAccountId, statementDay: nil)
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
                        budgetStore.setCreditCard(
                            accountId: selectedAccountId,
                            statementDay: selectedStatementDay,
                            dueOffsetDays: selectedDueOffset
                        )
                        showingAddSheet = false
                        editingAccountId = nil
                    }
                    .disabled(selectedAccountId.isEmpty)
                }
            }
        }
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

/// Row displaying card balance, current billing cycle dates, cycle spend, and payment due date.
private struct CreditCardCycleRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let account: Account
    let cycle: CreditCardCycle

    @State private var cycleSpend: Int = 0

    private var cycleRange: (start: DayDate, end: DayDate) {
        cycle.cycleRange()
    }

    private var cycleDateText: String {
        let startStr = Transaction.formattedDate(from: cycleRange.start.yyyymmdd, style: .abbreviated)
        let endStr = Transaction.formattedDate(from: cycleRange.end.yyyymmdd, style: .abbreviated)
        return "\(startStr) – \(endStr)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.name)
                    .font(.headline)
                Spacer()
                Text(budgetStore.displayBalance(account.balance))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(account.balance < 0 ? .red : .primary)
            }

            HStack {
                Label(cycleDateText, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(cycle.daysRemainingInCycle())d left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("Cycle spend: \(budgetStore.displayBalance(cycleSpend))", systemImage: "cart")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Label(cycle.dueSummary(), systemImage: "clock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
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
