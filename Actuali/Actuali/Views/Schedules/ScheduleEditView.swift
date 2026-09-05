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
                        Text(String(localized: "This schedule repeats on a pattern Actuali can't read, so it can't be edited here — saving would replace the pattern. Edit it in Actual instead."))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.footnote)
                }
            } else if editing?.isCustom == true {
                Section {
                    Label {
                        Text(String(localized: "This schedule has extra rule conditions set up in Actual. They're preserved when you save, but can't be edited here."))
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.footnote)
                }
            }
            Section {
                TextField(String(localized: "Name"), text: $name)
                TextField(String(localized: "Payee"), text: $payeeName)
                    .textInputAutocapitalization(.words)

                Picker(String(localized: "Account"), selection: $accountId) {
                    Text(String(localized: "Select an account")).tag(String?.none)
                    ForEach(openAccounts) { account in
                        Text(account.name).tag(String?.some(account.id))
                    }
                }
            } footer: {
                Text(String(localized: "A schedule needs an account. Leaving the payee blank matches only transactions that have no payee."))
            }

            amountSection
            dateSection

            Section {
                Toggle(String(localized: "Automatically Add Transaction"), isOn: $postsTransaction)

                Picker(String(localized: "Upcoming Window"), selection: $upcomingLength) {
                    Text(String(localized: "Budget Default")).tag(Self.defaultUpcomingLength)
                    Text(String(localized: "1 Day")).tag("1")
                    Text(String(localized: "1 Week")).tag("7")
                    Text(String(localized: "2 Weeks")).tag("14")
                    Text(String(localized: "1 Month")).tag("oneMonth")
                    Text(String(localized: "Rest of Month")).tag("currentMonth")
                }
            } footer: {
                Text(String(localized: "Automatically added transactions are created on your server when the app opens."))
            }
            if let editing {
                Section(String(localized: "Linked Transactions")) {
                    if linkedTransactions.isEmpty {
                        Text(String(localized: "No transactions linked yet."))
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
                                Text(budgetStore.displayBalance(transaction.amount))
                                    .monospacedDigit()
                            }
                            .swipeActions {
                                Button(String(localized: "Unlink")) {
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
                    Button(String(localized: "Delete Schedule"), role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .navigationTitle(isEditing ? String(localized: "Edit Schedule") : String(localized: "New Schedule"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save")) { Task { await save() } }
                    .disabled(isSaving || accountId == nil || hasUnreadableDate)
            }
        }
        .overlay {
            if isSaving { ProgressView().controlSize(.large) }
        }
        .alert(String(localized: "Couldn't Save Schedule"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "OK")) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            String(localized: "Delete this schedule?"),
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete Schedule"), role: .destructive) { Task { await delete() } }
        } message: {
            Text(String(localized: "Transactions this schedule already created are kept."))
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var amountSection: some View {
        Section(String(localized: "Amount")) {
            Picker(String(localized: "Type"), selection: $txType) {
                Text(String(localized: "Expense")).tag(TransactionType.expense)
                Text(String(localized: "Income")).tag(TransactionType.income)
            }
            .pickerStyle(.segmented)

            Picker(String(localized: "Matches"), selection: $amountOp) {
                ForEach(ScheduleAmountOp.allCases, id: \.self) { op in
                    Text(op.label).tag(op)
                }
            }

            HStack {
                Text(amountOp == .isBetween ? String(localized: "From") : String(localized: "Amount"))
                Spacer()
                AmountInputField(text: $amountText, alignment: .right)
                    .frame(maxWidth: 140)
            }

            if amountOp == .isBetween {
                HStack {
                    Text(String(localized: "To"))
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
            Toggle(String(localized: "Repeats"), isOn: $repeats)

            if repeats {
                NavigationLink {
                    RecurrenceEditorView(draft: $recurrence)
                } label: {
                    HStack {
                        Text(String(localized: "Repeat"))
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
