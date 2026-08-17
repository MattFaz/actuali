import SwiftUI

/// Create or edit a schedule (GH #221). Mirrors the web's schedule edit form:
/// name, payee, account, amount with an operator, a one-off or recurring date,
/// and the auto-post flag.
struct ScheduleEditView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    private let editing: ScheduleSummary?

    @State private var name: String
    @State private var payeeName: String
    @State private var accountId: String?
    @State private var txType: TransactionType
    @State private var amountOp: ScheduleAmountOp
    @State private var amountText: String
    @State private var amountHighText: String
    @State private var repeats: Bool
    @State private var oneOffDate: Date
    @State private var recurrence: RecurrenceDraft
    @State private var postsTransaction: Bool
    @State private var upcomingLength: String

    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    
    @State private var linkedTransactions: [Transaction] = []

    /// "Use the budget default" is modelled as an empty string rather than nil
    /// so it can ride in a `Picker` selection.
    private static let defaultUpcomingLength = ""

    init(editing: ScheduleSummary? = nil, budgetStore: BudgetStore) {
        self.editing = editing

        let payee = editing?.payeeId.flatMap { id in
            budgetStore.payees.first { $0.id == id }?.name
        }
        _name = State(initialValue: editing?.name ?? "")
        _payeeName = State(initialValue: payee ?? "")
        _accountId = State(initialValue: editing?.accountId
            ?? budgetStore.accounts.first { !$0.closed }?.id)
        _postsTransaction = State(initialValue: editing?.postsTransaction ?? false)
        _upcomingLength = State(initialValue: editing?.customUpcomingLength
            ?? Self.defaultUpcomingLength)
        _amountOp = State(initialValue: editing?.amountOp ?? .isApprox)

        // Amounts are signed cents; the form edits a magnitude plus a
        // direction, the same way the transaction form does.
        let amount = editing?.amount
        let isIncome = (editing?.postAmount ?? -1) > 0
        _txType = State(initialValue: isIncome ? .income : .expense)
        switch amount {
        case .range(let low, let high):
            _amountText = State(initialValue: Self.dollars(min(abs(low), abs(high))))
            _amountHighText = State(initialValue: Self.dollars(max(abs(low), abs(high))))
        case .fixed(let cents):
            _amountText = State(initialValue: Self.dollars(abs(cents)))
            _amountHighText = State(initialValue: "")
        case nil:
            _amountText = State(initialValue: "")
            _amountHighText = State(initialValue: "")
        }

        switch editing?.dateCondition {
        case .recurring(let config):
            _repeats = State(initialValue: true)
            _recurrence = State(initialValue: RecurrenceDraft(config: config))
            _oneOffDate = State(initialValue: Date())
        case .fixed(let day):
            _repeats = State(initialValue: false)
            _recurrence = State(initialValue: RecurrenceDraft(config: nil))
            _oneOffDate = State(initialValue: Transaction.date(fromYYYYMMDD: day.yyyymmdd))
        case .unsupported, nil:
            _repeats = State(initialValue: false)
            _recurrence = State(initialValue: RecurrenceDraft(config: nil))
            _oneOffDate = State(initialValue: Date())
        }
    }

    private var isEditing: Bool { editing != nil }

    /// The rule carries a date condition we couldn't parse — `dateOp` is set
    /// but `RecurConfig` rejected the value (a legacy string interval, an
    /// out-of-range pattern, a bounded end mode with no bound).
    ///
    /// The form has nothing to show for it, so it falls back to a one-off
    /// today; saving that would overwrite the stored recurrence and push the
    /// loss to the server. Refuse instead. A schedule with NO date condition
    /// (`dateOp == nil`) is the broken-rule repair case and still saves.
    private var hasUnreadableDate: Bool {
        editing?.dateCondition == .unsupported && editing?.dateOp != nil
    }

    var body: some View {
        Form {
            if hasUnreadableDate {
                Section {
                    Label {
                        Text("This schedule repeats on a pattern Actuali can't read, so it can't be edited here — saving would replace the pattern. Edit it in Actual instead.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.footnote)
                }
            } else if editing?.isCustom == true {
                Section {
                    Label {
                        Text("This schedule has extra rule conditions set up in Actual. They're preserved when you save, but can't be edited here.")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.footnote)
                }
            }
            Section {
                TextField("Name", text: $name)
                TextField("Payee", text: $payeeName)
                    .textInputAutocapitalization(.words)

                Picker("Account", selection: $accountId) {
                    Text("Select an account").tag(String?.none)
                    ForEach(openAccounts) { account in
                        Text(account.name).tag(String?.some(account.id))
                    }
                }
            } footer: {
                Text("A schedule needs an account. Leaving the payee blank matches only transactions that have no payee.")
            }

            amountSection
            dateSection

            Section {
                Toggle("Automatically Add Transaction", isOn: $postsTransaction)

                Picker("Upcoming Window", selection: $upcomingLength) {
                    Text("Budget Default").tag(Self.defaultUpcomingLength)
                    Text("1 Day").tag("1")
                    Text("1 Week").tag("7")
                    Text("2 Weeks").tag("14")
                    Text("1 Month").tag("oneMonth")
                    Text("Rest of Month").tag("currentMonth")
                }
            } footer: {
                Text("Automatically added transactions are created on your server when the app opens, if “Post Scheduled Transactions” is on in Settings.")
            }
            if let editing {
                Section("Linked Transactions") {
                    if linkedTransactions.isEmpty {
                        Text("No transactions linked yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(linkedTransactions) { transaction in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(transaction.payeeName ?? "No payee")
                                    Text(transaction.dateFormatted)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(budgetStore.formatCurrency(transaction.amount))
                                    .monospacedDigit()
                            }
                            .swipeActions {
                                Button("Unlink") {
                                    Task {
                                        try? await budgetStore.linkTransactions([transaction], to: nil)
                                        await loadLinkedTransactions(editing.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .task { await loadLinkedTransactions(editing.id) }
            }
            if isEditing {
                Section {
                    Button("Delete Schedule", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .navigationTitle(isEditing ? "Edit Schedule" : "New Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(isSaving || accountId == nil || hasUnreadableDate)
            }
        }
        .overlay {
            if isSaving { ProgressView().controlSize(.large) }
        }
        .alert("Couldn't Save Schedule", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete this schedule?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Schedule", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Transactions this schedule already created are kept.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var amountSection: some View {
        Section("Amount") {
            Picker("Type", selection: $txType) {
                Text("Expense").tag(TransactionType.expense)
                Text("Income").tag(TransactionType.income)
            }
            .pickerStyle(.segmented)

            Picker("Matches", selection: $amountOp) {
                ForEach(ScheduleAmountOp.allCases, id: \.self) { op in
                    Text(op.label).tag(op)
                }
            }

            HStack {
                Text(amountOp == .isBetween ? "From" : "Amount")
                Spacer()
                AmountInputField(text: $amountText, alignment: .right)
                    .frame(maxWidth: 140)
            }

            if amountOp == .isBetween {
                HStack {
                    Text("To")
                    Spacer()
                    AmountInputField(text: $amountHighText, alignment: .right)
                        .frame(maxWidth: 140)
                }
            }
        }
    }

    @ViewBuilder
    private var dateSection: some View {
        Section {
            Toggle("Repeats", isOn: $repeats)

            if repeats {
                NavigationLink {
                    RecurrenceEditorView(draft: $recurrence)
                } label: {
                    HStack {
                        Text("Repeat")
                        Spacer()
                        Text(ScheduleDescription.recurring(recurrence.config))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } else {
                DatePicker("Date", selection: $oneOffDate, displayedComponents: .date)
            }
        } header: {
            Text("Date")
        } footer: {
            if repeats {
                Text("Next: " + ScheduleRecurrence
                    .upcomingDates(for: recurrence.config, count: 1)
                    .map(ScheduleDescription.mediumDate)
                    .joined())
            }
        }
    }

    // MARK: - Data

    private var openAccounts: [Account] {
        budgetStore.accounts.filter { !$0.closed }
    }

    private static func dollars(_ cents: Int) -> String {
        cents == 0 ? "" : String(format: "%.2f", Double(cents) / 100.0)
    }

    private func cents(_ text: String) -> Int? {
        guard let value = AmountParser.parse(text) else { return nil }
        return Transaction.cents(fromDollars: abs(value))
    }

    /// Assemble the form into the shape the write path takes, resolving (or
    /// creating) the payee on the way — same as the transaction form.
    private func buildFields() async throws -> ScheduleFormFields {
        let sign = txType == .income ? 1 : -1

        let amount: ScheduledAmount
        if amountOp == .isBetween {
            guard let low = cents(amountText), let high = cents(amountHighText) else {
                throw BudgetStoreError.invalidAmount
            }
            // Signing flips the ordering for expenses; Actual stores num1 <= num2.
            let a = sign * low, b = sign * high
            amount = .range(min(a, b), max(a, b))
        } else {
            guard let value = cents(amountText) else { throw BudgetStoreError.invalidAmount }
            amount = .fixed(sign * value)
        }

        let date: ScheduleDateCondition = repeats
            ? .recurring(recurrence.config)
            : .fixed(DayDate(yyyymmdd: Transaction.yyyymmdd(from: oneOffDate))
                ?? DayDate.today())

        let trimmedPayee = payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let payeeId = try await budgetStore.resolvePayeeId(name: trimmedPayee, editing: nil)

        return ScheduleFormFields(
            name: name,
            payeeId: payeeId,
            accountId: accountId,
            amount: amount,
            amountOp: amountOp,
            date: date,
            postsTransaction: postsTransaction,
            customUpcomingLength: upcomingLength.isEmpty ? nil : upcomingLength)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let fields = try await buildFields()
            if let editing {
                try await budgetStore.updateSchedule(editing, fields: fields)
            } else {
                try await budgetStore.createSchedule(fields: fields)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() async {
        guard let editing else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await budgetStore.deleteSchedule(editing)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func loadLinkedTransactions(_ scheduleId: String) async {
        linkedTransactions = await budgetStore.fetchScheduleTransactions(scheduleId)
    }
}
