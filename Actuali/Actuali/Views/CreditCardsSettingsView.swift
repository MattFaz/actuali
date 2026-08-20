import SwiftUI

/// View for managing credit card accounts and their monthly billing cycles.
struct CreditCardsSettingsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var showingAddSheet = false
    @State private var editingAccountId: String?
    @State private var selectedAccountId = ""
    @State private var selectedStatementDay = 15

    private var activeAccounts: [Account] {
        budgetStore.accounts.filter { !$0.closed }
    }

    private var configuredCards: [(account: Account, cycle: CreditCardCycle)] {
        let accountsById = Dictionary(uniqueKeysWithValues: budgetStore.accounts.map { ($0.id, $0) })
        return budgetStore.creditCardStatementDays.compactMap { accountId, statementDay in
            guard let account = accountsById[accountId], !account.closed else { return nil }
            return (account: account, cycle: CreditCardCycle(statementDay: statementDay))
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
                Text("Mark accounts as credit cards and track their monthly billing cycles, cycle spend, and upcoming payment due dates (assumed 15 days after statement closing).")
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
            budgetStore.setCreditCardStatementDay(accountId: accountId, statementDay: nil)
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
                } header: {
                    Text("Card Details")
                } footer: {
                    Text("Payment due date is automatically calculated as 15 days after the statement closing date.")
                }

                if isEditing {
                    Section {
                        Button("Remove Credit Card Tracking", role: .destructive) {
                            budgetStore.setCreditCardStatementDay(accountId: selectedAccountId, statementDay: nil)
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
                        budgetStore.setCreditCardStatementDay(
                            accountId: selectedAccountId,
                            statementDay: selectedStatementDay
                        )
                        showingAddSheet = false
                        editingAccountId = nil
                    }
                    .disabled(selectedAccountId.isEmpty)
                }
            }
        }
    }

    private func dayOrdinal(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)th"
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

    private var dueDateText: String {
        let due = cycle.upcomingDueDate()
        let dueStr = Transaction.formattedDate(from: due.yyyymmdd, style: .abbreviated)
        let days = cycle.daysUntilDue()
        if days == 0 {
            return "Due today"
        } else if days == 1 {
            return "Due tomorrow"
        } else {
            return "Due \(dueStr) (\(days)d)"
        }
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
                Label(dueDateText, systemImage: "clock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .task(id: cycle.statementDay) {
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
