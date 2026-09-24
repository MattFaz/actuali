import SwiftUI

/// Add or edit one deposit's terms. Mirrors `LoanEditorView`, including the
/// two modes and priming its fields in `init` rather than `onAppear`.
struct DepositEditorView: View {
    /// Adding picks the account; editing already knows it and primes the
    /// fields from the stored config.
    enum Mode: Equatable {
        case add
        case edit(accountId: String, config: DepositConfig)
    }

    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var selectedAccountId: String
    @State private var kind: DepositConfig.Kind
    /// Dot-decimal amounts as typed, the format `AmountInputField` binds to.
    @State private var amountText: String
    /// Annual rate as typed, e.g. "7.1". Parsed with `AmountParser` so a comma
    /// decimal separator works in the locales that use one.
    @State private var rateText: String
    @State private var compounding: DepositConfig.Compounding
    @State private var openedOn: Date
    @State private var termText: String

    /// State is primed here rather than in `onAppear` so the fields never
    /// render empty for a frame before the stored values land.
    init(mode: Mode, defaultAccountId: String = "") {
        self.mode = mode
        switch mode {
        case .add:
            _selectedAccountId = State(initialValue: defaultAccountId)
            _kind = State(initialValue: .fixed)
            _amountText = State(initialValue: "")
            _rateText = State(initialValue: "")
            _compounding = State(initialValue: .quarterly)
            _openedOn = State(initialValue: Date())
            _termText = State(initialValue: "")
        case .edit(let accountId, let config):
            _selectedAccountId = State(initialValue: accountId)
            _kind = State(initialValue: config.kind)
            _amountText = State(initialValue: LoanEditorView.amountText(config.amount))
            _rateText = State(initialValue: LoanEditorView.rateText(config.annualRatePercent))
            _compounding = State(initialValue: config.compounding)
            _openedOn = State(initialValue: config.openedOn.utcDate)
            _termText = State(initialValue: String(config.termMonths))
        }
    }

    private var isEditing: Bool {
        if case .edit = mode {
            return true
        }
        return false
    }

    /// Accounts with no deposit config yet, savings-ish types first.
    var unconfiguredAccounts: [Account] {
        let configuredIds = Set(budgetStore.depositConfigs.keys)
        return budgetStore.accounts
            .filter { !$0.closed && !configuredIds.contains($0.id) }
            .sorted { (Self.typeRank($0.type), $0.name) < (Self.typeRank($1.type), $1.name) }
    }

    /// Savings and investment accounts sort to the top: a deposit is money put
    /// aside, so those are what someone opening this screen is reaching for.
    /// The debt types sort last — they run the other way.
    nonisolated static func typeRank(_ type: AccountType) -> Int {
        switch type {
        case .savings, .investment: 0
        case .credit, .mortgage, .debt: 2
        default: 1
        }
    }

    nonisolated static func months(from text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return min(value, DepositGrowth.maxTermMonths)
    }

    var enteredConfig: DepositConfig? {
        Self.config(
            kind: kind,
            amount: amountText,
            rate: rateText,
            compounding: compounding,
            openedOn: DayDate.today(now: openedOn),
            term: termText
        )
    }

    /// nil when the entry can't make a usable deposit, which is what disables
    /// Save. A deposit needs a positive amount and a term; the rate may be
    /// absent, because a zero-interest deposit is a real if joyless thing.
    ///
    /// Pure so the validation rule can be covered without building a view —
    /// the same seam `LoanEditorView.config` uses.
    nonisolated static func config(
        kind: DepositConfig.Kind,
        amount: String,
        rate: String,
        compounding: DepositConfig.Compounding,
        openedOn: DayDate,
        term: String
    ) -> DepositConfig? {
        guard let amount = LoanEditorView.cents(from: amount), amount > 0,
              let termMonths = months(from: term) else { return nil }
        return DepositConfig(
            kind: kind,
            amount: amount,
            annualRatePercent: max(0, AmountParser.parse(rate) ?? 0),
            compounding: compounding,
            openedOn: openedOn,
            termMonths: termMonths
        )
    }

    /// The instalment on a recurring deposit, the lump sum on a fixed one.
    private var amountLabel: String {
        kind == .recurring
            ? String(localized: "Monthly Instalment")
            : String(localized: "Deposit Amount")
    }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                if isEditing {
                    Section {
                        Button(String(localized: "Remove Deposit Tracking"), role: .destructive) {
                            let accountId = selectedAccountId
                            Task { await budgetStore.setDeposit(accountId: accountId, config: nil) }
                            dismiss()
                        }
                        .accessibilityIdentifier("depositEditor.remove")
                    }
                }
            }
            .navigationTitle(isEditing ? String(localized: "Edit Deposit") : String(localized: "Add Deposit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        if let config = enteredConfig {
                            let accountId = selectedAccountId
                            Task { await budgetStore.setDeposit(accountId: accountId, config: config) }
                        }
                        dismiss()
                    }
                    .disabled(selectedAccountId.isEmpty || enteredConfig == nil)
                    .accessibilityIdentifier("depositEditor.save")
                }
            }
        }
    }

    private var detailsSection: some View {
        Section {
            if isEditing {
                if let account = budgetStore.accounts.first(where: { $0.id == selectedAccountId }) {
                    LabeledContent(String(localized: "Account"), value: account.name)
                }
            } else {
                Picker(String(localized: "Account"), selection: $selectedAccountId) {
                    ForEach(unconfiguredAccounts) { account in
                        Text(account.name).tag(account.id)
                    }
                }
            }

            Picker(String(localized: "Type"), selection: $kind) {
                Text(String(localized: "Fixed Deposit")).tag(DepositConfig.Kind.fixed)
                Text(String(localized: "Recurring Deposit")).tag(DepositConfig.Kind.recurring)
            }
            .accessibilityIdentifier("depositEditor.kind")

            HStack {
                Text(amountLabel)
                Spacer()
                AmountInputField(
                    text: $amountText,
                    conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                    alignment: .right
                )
                .accessibilityIdentifier("depositEditor.amount")
            }

            HStack {
                Text(String(localized: "Interest Rate"))
                Spacer()
                TextField("0", text: $rateText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("depositEditor.interestRate")
                Text(verbatim: "%")
                    .foregroundStyle(.secondary)
            }

            Picker(String(localized: "Compounding"), selection: $compounding) {
                ForEach(DepositConfig.Compounding.allCases, id: \.self) { frequency in
                    Text(Self.compoundingLabel(frequency)).tag(frequency)
                }
            }
            .accessibilityIdentifier("depositEditor.compounding")

            DatePicker(
                String(localized: "Opened"),
                selection: $openedOn,
                displayedComponents: .date
            )
            .accessibilityIdentifier("depositEditor.openedOn")

            HStack {
                Text(String(localized: "Term"))
                Spacer()
                TextField("0", text: $termText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("depositEditor.term")
                Text(String(localized: "months"))
                    .foregroundStyle(.secondary)
            }

            // The term is entered in months but thought about as a date, so
            // the maturity is shown rather than left to be worked out.
            if let config = enteredConfig {
                LabeledContent(
                    String(localized: "Matures"),
                    value: config.maturityDate.utcDate.formatted(date: .abbreviated, time: .omitted)
                )
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("depositEditor.matures")
            }
        } header: {
            Text(String(localized: "Deposit Details"))
        } footer: {
            Text(String(localized: "A fixed deposit is one lump sum left for the term. A recurring deposit takes the same amount every month.\n\nInterest is credited on whole compounding periods, so the value steps up at the end of each one rather than growing smoothly — the same way your bank reports it."))
        }
    }

    nonisolated static func compoundingLabel(_ frequency: DepositConfig.Compounding) -> String {
        switch frequency {
        case .annually: String(localized: "Annually")
        case .semiAnnually: String(localized: "Semi-annually")
        case .quarterly: String(localized: "Quarterly")
        case .monthly: String(localized: "Monthly")
        }
    }
}
