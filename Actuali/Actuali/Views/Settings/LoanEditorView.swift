import SwiftUI

/// Add or edit one loan's terms. Extracted from `LoansSettingsView` so the
/// account screen can open the same editor for the loan it is already
/// showing, rather than sending the user back out to the Loans list.
struct LoanEditorView: View {
    /// Adding picks the account; editing already knows it and primes the
    /// fields from the stored config.
    enum Mode: Equatable {
        case add
        case edit(accountId: String, config: LoanConfig)
    }

    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var selectedAccountId: String
    /// Dot-decimal amounts as typed, the format `AmountInputField` binds to.
    @State private var originalBalanceText: String
    @State private var paymentText: String
    /// Empty means "no escrow", the same way an empty credit limit means "no limit".
    @State private var escrowText: String
    /// Annual rate as typed, e.g. "6.25". Parsed with `AmountParser` so a
    /// comma decimal separator works in the locales that use one.
    @State private var rateText: String

    /// State is primed here rather than in `onAppear` so the fields never
    /// render empty for a frame before the stored values land.
    init(mode: Mode, defaultAccountId: String = "") {
        self.mode = mode
        switch mode {
        case .add:
            _selectedAccountId = State(initialValue: defaultAccountId)
            _originalBalanceText = State(initialValue: "")
            _paymentText = State(initialValue: "")
            _escrowText = State(initialValue: "")
            _rateText = State(initialValue: "")
        case .edit(let accountId, let config):
            _selectedAccountId = State(initialValue: accountId)
            _originalBalanceText = State(initialValue: Self.amountText(config.originalBalance))
            _paymentText = State(initialValue: Self.amountText(config.minimumPayment))
            _escrowText = State(initialValue: config.escrowOrFees.map(Self.amountText) ?? "")
            _rateText = State(initialValue: Self.rateText(config.annualRatePercent))
        }
    }

    private var isEditing: Bool {
        if case .edit = mode {
            return true
        }
        return false
    }

    /// Accounts with no loan config yet, loan-ish types first.
    var unconfiguredAccounts: [Account] {
        let configuredIds = Set(budgetStore.loanConfigs.keys)
        return budgetStore.accounts
            .filter { !$0.closed && !configuredIds.contains($0.id) }
            .sorted { (Self.typeRank($0.type), $0.name) < (Self.typeRank($1.type), $1.name) }
    }

    /// Mortgage and debt accounts sort to the top of the picker: they are what
    /// someone opening this screen is almost always reaching for. Cards sort
    /// last — YNAB steers credit-card debt to the card type instead.
    nonisolated static func typeRank(_ type: AccountType) -> Int {
        switch type {
        case .mortgage, .debt: 0
        case .credit: 2
        default: 1
        }
    }

    /// Dot-decimal, matching what `AmountInputField` round-trips.
    nonisolated static func amountText(_ cents: Int) -> String {
        String(format: "%.2f", Double(cents) / 100.0)
    }

    /// Trailing zeros trimmed so a whole-number rate reads "6", not "6.00".
    nonisolated static func rateText(_ percent: Double) -> String {
        percent == percent.rounded() ? String(Int(percent)) : String(percent)
    }

    nonisolated static func cents(from text: String) -> Int? {
        guard let dollars = AmountParser.parse(text) else { return nil }
        return Transaction.cents(fromDollars: dollars)
    }

    var enteredConfig: LoanConfig? {
        Self.config(
            originalBalance: originalBalanceText,
            rate: rateText,
            payment: paymentText,
            escrow: escrowText
        )
    }

    /// nil when the entry can't make a usable loan, which is what disables
    /// Save. A loan needs a positive original balance and a payment; the rate
    /// and escrow are allowed to be absent (a 0% family loan is real, and
    /// escrow only applies to mortgages).
    ///
    /// Pure so the validation rule can be covered without building a view —
    /// the same seam `AccountDetailView.showsNote` uses.
    nonisolated static func config(
        originalBalance: String,
        rate: String,
        payment: String,
        escrow: String
    ) -> LoanConfig? {
        guard let balance = cents(from: originalBalance), balance > 0,
              let monthly = cents(from: payment), monthly > 0 else { return nil }
        return LoanConfig(
            originalBalance: balance,
            annualRatePercent: max(0, AmountParser.parse(rate) ?? 0),
            minimumPayment: monthly,
            escrowOrFees: cents(from: escrow).flatMap { $0 > 0 ? $0 : nil }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
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

                    HStack {
                        Text(String(localized: "Original Balance"))
                        Spacer()
                        AmountInputField(
                            text: $originalBalanceText,
                            conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                            alignment: .right
                        )
                        .accessibilityIdentifier("loanEditor.originalBalance")
                    }

                    HStack {
                        Text(String(localized: "Interest Rate"))
                        Spacer()
                        TextField("0", text: $rateText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("loanEditor.interestRate")
                        Text(verbatim: "%")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text(String(localized: "Monthly Payment"))
                        Spacer()
                        AmountInputField(
                            text: $paymentText,
                            conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                            alignment: .right
                        )
                        .accessibilityIdentifier("loanEditor.monthlyPayment")
                    }

                    HStack {
                        Text(String(localized: "Escrow or Fees"))
                        Spacer()
                        AmountInputField(
                            text: $escrowText,
                            conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                            alignment: .right
                        )
                        .accessibilityIdentifier("loanEditor.escrow")
                    }
                } header: {
                    Text(String(localized: "Loan Details"))
                } footer: {
                    Text(String(localized: "The original balance is what you owed when the loan started — payoff progress is measured against it. Interest is compounded monthly, and each payment covers interest and any escrow before the rest comes off the principal.\n\nEscrow or fees applies to mortgages whose payment bundles them in. Leave it empty to skip."))
                }

                if isEditing {
                    Section {
                        Button(String(localized: "Remove Loan Tracking"), role: .destructive) {
                            let accountId = selectedAccountId
                            Task { await budgetStore.setLoan(accountId: accountId, config: nil) }
                            dismiss()
                        }
                        .accessibilityIdentifier("loanEditor.remove")
                    }
                }
            }
            .navigationTitle(isEditing ? String(localized: "Edit Loan") : String(localized: "Add Loan"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        if let config = enteredConfig {
                            let accountId = selectedAccountId
                            Task { await budgetStore.setLoan(accountId: accountId, config: config) }
                        }
                        dismiss()
                    }
                    .disabled(selectedAccountId.isEmpty || enteredConfig == nil)
                    .accessibilityIdentifier("loanEditor.save")
                }
            }
        }
    }
}
