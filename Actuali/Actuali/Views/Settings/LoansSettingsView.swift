import SwiftUI

/// Manages which accounts are tracked as loans and the terms behind each one.
/// Mirrors `CreditCardsSettingsView`: the config it edits rides in the same
/// synced `preferences` table, and a closed account keeps its config but drops
/// out of the list.
struct LoansSettingsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var showingAddSheet = false
    @State private var editingAccountId: String?
    @State private var selectedAccountId = ""
    /// Dot-decimal amounts as typed, the format `AmountInputField` binds to.
    @State private var selectedOriginalBalanceText = ""
    @State private var selectedPaymentText = ""
    /// Empty means "no escrow", the same way an empty credit limit means "no limit".
    @State private var selectedEscrowText = ""
    /// Annual rate as typed, e.g. "6.25". Parsed with `AmountParser` so a
    /// comma decimal separator works in the locales that use one.
    @State private var selectedRateText = ""

    private var configuredLoans: [(account: Account, config: LoanConfig)] {
        let accountsById = Dictionary(uniqueKeysWithValues: budgetStore.accounts.map { ($0.id, $0) })
        return budgetStore.activeLoanConfigs
            .compactMap { accountId, config in
                guard let account = accountsById[accountId] else { return nil }
                return (account: account, config: config)
            }
            .sorted { $0.account.name.localizedCaseInsensitiveCompare($1.account.name) == .orderedAscending }
    }

    private var unconfiguredAccounts: [Account] {
        let configuredIds = Set(budgetStore.loanConfigs.keys)
        return budgetStore.accounts
            .filter { !$0.closed && !configuredIds.contains($0.id) }
            .sorted { (Self.typeRank($0.type), $0.name) < (Self.typeRank($1.type), $1.name) }
    }

    /// Mortgage and debt accounts sort to the top of the picker: they are what
    /// someone opening this screen is almost always reaching for.
    nonisolated static func typeRank(_ type: AccountType) -> Int {
        switch type {
        case .mortgage, .debt: 0
        case .credit: 2
        default: 1
        }
    }

    var body: some View {
        List {
            Section(String(localized: "Configured Loans")) {
                if configuredLoans.isEmpty {
                    Text(String(localized: "Track a loan's balance, interest rate and payoff date, and watch the principal come down as you pay."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    let loans = configuredLoans
                    let detached = budgetStore.syncDetachedByRestore
                    ForEach(loans, id: \.account.id) { item in
                        Button {
                            beginEditing(item)
                        } label: {
                            LoanSummaryRow(account: item.account, config: item.config)
                        }
                        .buttonStyle(.plain)
                        .disabled(detached)
                        .accessibilityIdentifier("loanRow.\(item.account.id)")
                    }
                    .onDelete { offsets in
                        for accountId in offsets.map({ loans[$0].account.id }) {
                            Task { await budgetStore.setLoan(accountId: accountId, config: nil) }
                        }
                    }
                    .deleteDisabled(detached)
                }
            }

            if budgetStore.syncDetachedByRestore {
                Section {
                    Text(String(localized: "Loan settings sync with your budget. Re-download this budget to change them."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if !unconfiguredAccounts.isEmpty {
                Section {
                    Button {
                        beginAdding()
                    } label: {
                        Label(String(localized: "Add Loan"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("loanSettings.add")
                }
            }
        }
        .navigationTitle(String(localized: "Loans"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddSheet) {
            loanSheet(isEditing: false)
        }
        .sheet(isPresented: Binding(
            get: { editingAccountId != nil },
            set: {
                if !$0 {
                    editingAccountId = nil
                }
            }
        )) {
            loanSheet(isEditing: true)
        }
    }

    private func beginAdding() {
        if let first = unconfiguredAccounts.first {
            selectedAccountId = first.id
        }
        selectedOriginalBalanceText = ""
        selectedRateText = ""
        selectedPaymentText = ""
        selectedEscrowText = ""
        showingAddSheet = true
    }

    private func beginEditing(_ item: (account: Account, config: LoanConfig)) {
        selectedAccountId = item.account.id
        selectedOriginalBalanceText = Self.amountText(item.config.originalBalance)
        selectedPaymentText = Self.amountText(item.config.minimumPayment)
        selectedEscrowText = item.config.escrowOrFees.map(Self.amountText) ?? ""
        selectedRateText = Self.rateText(item.config.annualRatePercent)
        editingAccountId = item.account.id
    }

    /// Dot-decimal, matching what `AmountInputField` round-trips.
    nonisolated static func amountText(_ cents: Int) -> String {
        String(format: "%.2f", Double(cents) / 100.0)
    }

    /// Trailing zeros trimmed so a whole-number rate reads "6", not "6.00".
    nonisolated static func rateText(_ percent: Double) -> String {
        percent == percent.rounded() ? String(Int(percent)) : String(percent)
    }

    private func loanSheet(isEditing: Bool) -> some View {
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
                            text: $selectedOriginalBalanceText,
                            conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                            alignment: .right
                        )
                        .accessibilityIdentifier("loanEditor.originalBalance")
                    }

                    HStack {
                        Text(String(localized: "Interest Rate"))
                        Spacer()
                        TextField("0", text: $selectedRateText)
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
                            text: $selectedPaymentText,
                            conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                            alignment: .right
                        )
                        .accessibilityIdentifier("loanEditor.monthlyPayment")
                    }

                    HStack {
                        Text(String(localized: "Escrow or Fees"))
                        Spacer()
                        AmountInputField(
                            text: $selectedEscrowText,
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
                            Task { await budgetStore.setLoan(accountId: selectedAccountId, config: nil) }
                            editingAccountId = nil
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
                        showingAddSheet = false
                        editingAccountId = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        if let config = enteredConfig {
                            let accountId = selectedAccountId
                            Task { await budgetStore.setLoan(accountId: accountId, config: config) }
                        }
                        showingAddSheet = false
                        editingAccountId = nil
                    }
                    .disabled(selectedAccountId.isEmpty || enteredConfig == nil)
                    .accessibilityIdentifier("loanEditor.save")
                }
            }
        }
    }

    /// nil when the entry can't make a usable loan, which is what disables
    /// Save. A loan needs a positive original balance and a payment; the rate
    /// and escrow are allowed to be absent (a 0% family loan is real).
    private var enteredConfig: LoanConfig? {
        guard let originalBalance = Self.cents(from: selectedOriginalBalanceText), originalBalance > 0,
              let payment = Self.cents(from: selectedPaymentText), payment > 0 else { return nil }
        return LoanConfig(
            originalBalance: originalBalance,
            annualRatePercent: max(0, AmountParser.parse(selectedRateText) ?? 0),
            minimumPayment: payment,
            escrowOrFees: Self.cents(from: selectedEscrowText).flatMap { $0 > 0 ? $0 : nil }
        )
    }

    nonisolated static func cents(from text: String) -> Int? {
        guard let dollars = AmountParser.parse(text) else { return nil }
        return Transaction.cents(fromDollars: dollars)
    }
}

/// Compact loan row: name and what's still owed on top, payoff summary and
/// progress underneath.
struct LoanSummaryRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let account: Account
    let config: LoanConfig

    private var balance: Int {
        budgetStore.accounts.first { $0.id == account.id }?.balance ?? account.balance
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.name)
                    .fontWeight(.medium)
                Spacer()
                Text(budgetStore.displayBalance(balance))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: config.fractionPaidOff(accountBalance: balance))
                .tint(.accentColor)

            HStack {
                Text(Self.progressText(config.fractionPaidOff(accountBalance: balance)))
                Spacer()
                Text(config.payoffSummary(accountBalance: balance))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "10.0% Paid Off", matching YNAB's own wording on the loan overview.
    nonisolated static func progressText(_ fraction: Double) -> String {
        String(format: String(localized: "%@ Paid Off"), percentText(fraction))
    }

    nonisolated static func percentText(_ fraction: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: fraction)) ?? "0%"
    }
}
