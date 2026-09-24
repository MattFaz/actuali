import SwiftUI

/// Record a loan payment: what left the funding account, and how much of it
/// the lender kept as interest and escrow before the rest came off the
/// balance.
///
/// The estimate is a starting point, not a commitment — the lender's actual
/// charge is often a cent or two off a monthly model, and YNAB lets you
/// correct it, so interest and escrow stay editable and the principal follows
/// from them rather than the other way round.
struct LoanPaymentView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    let account: Account
    let config: LoanConfig

    @State private var fundingAccountId: String
    @State private var paymentText: String
    @State private var interestText: String
    @State private var escrowText: String
    @State private var date: Date
    @State private var recording = false

    /// Primed in `init` for the same reason `LoanEditorView` does it: the
    /// fields would otherwise render empty for a frame.
    init(account: Account, config: LoanConfig, balance: Int, today: Date = Date()) {
        self.account = account
        self.config = config
        let split = config.paymentSplit(
            accountBalance: balance,
            payment: config.suggestedPayment(accountBalance: balance)
        )
        _fundingAccountId = State(initialValue: "")
        _paymentText = State(initialValue: LoanEditorView.amountText(
            config.suggestedPayment(accountBalance: balance)
        ))
        _interestText = State(initialValue: LoanEditorView.amountText(split.interest))
        _escrowText = State(initialValue: LoanEditorView.amountText(split.escrow))
        _date = State(initialValue: today)
    }

    /// Where the money comes from: an open, on-budget account that isn't the
    /// loan. Paying a loan from another off-budget account would leave the
    /// budget untouched, which defeats the point of pairing a category.
    nonisolated static func fundingAccounts(_ accounts: [Account], loanAccountId: String) -> [Account] {
        accounts
            .filter { !$0.closed && !$0.offBudget && $0.id != loanAccountId }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    private var availableFundingAccounts: [Account] {
        Self.fundingAccounts(budgetStore.accounts, loanAccountId: account.id)
    }

    private var balance: Int {
        budgetStore.accounts.first { $0.id == account.id }?.balance ?? account.balance
    }

    private var payment: Int {
        LoanEditorView.cents(from: paymentText) ?? 0
    }

    private var interest: Int {
        LoanEditorView.cents(from: interestText) ?? 0
    }

    private var escrow: Int {
        config.escrowOrFees == nil ? 0 : LoanEditorView.cents(from: escrowText) ?? 0
    }

    /// What actually comes off the balance. Can go negative, and says so
    /// rather than clamping: a payment that doesn't cover the lender's
    /// charges grows the loan, which is the case most worth surfacing.
    nonisolated static func principal(payment: Int, interest: Int, escrow: Int) -> Int {
        payment - interest - escrow
    }

    private var principal: Int {
        Self.principal(payment: payment, interest: interest, escrow: escrow)
    }

    private var canRecord: Bool {
        payment > 0 && !fundingAccountId.isEmpty && !recording && !budgetStore.syncDetachedByRestore
    }

    var body: some View {
        NavigationStack {
            Form {
                paymentSection
                breakdownSection
                categorySection
            }
            .navigationTitle(String(localized: "Record Payment"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Record")) { record() }
                        .disabled(!canRecord)
                        .accessibilityIdentifier("loanPayment.record")
                }
            }
            .onAppear {
                if fundingAccountId.isEmpty {
                    fundingAccountId = availableFundingAccounts.first?.id ?? ""
                }
            }
        }
    }

    private var paymentSection: some View {
        Section {
            Picker(String(localized: "From"), selection: $fundingAccountId) {
                ForEach(availableFundingAccounts) { funding in
                    Text(funding.name).tag(funding.id)
                }
            }
            .accessibilityIdentifier("loanPayment.fromAccount")

            DatePicker(
                String(localized: "Date"),
                selection: $date,
                displayedComponents: .date
            )
            .accessibilityIdentifier("loanPayment.date")

            HStack {
                Text(String(localized: "Payment"))
                Spacer()
                AmountInputField(
                    text: $paymentText,
                    conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                    alignment: .right
                )
                .accessibilityIdentifier("loanPayment.amount")
            }
        } footer: {
            if availableFundingAccounts.isEmpty {
                Text(String(localized: "A loan payment has to come from an open, on-budget account. Add one first."))
            }
        }
    }

    private var breakdownSection: some View {
        Section {
            HStack {
                Text(String(localized: "Interest"))
                Spacer()
                AmountInputField(
                    text: $interestText,
                    conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                    alignment: .right
                )
                .accessibilityIdentifier("loanPayment.interest")
            }

            if config.escrowOrFees != nil {
                HStack {
                    Text(String(localized: "Escrow or Fees"))
                    Spacer()
                    AmountInputField(
                        text: $escrowText,
                        conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                        alignment: .right
                    )
                    .accessibilityIdentifier("loanPayment.escrow")
                }
            }

            LabeledContent(
                String(localized: "Principal"),
                value: budgetStore.displayBalance(principal)
            )
            .accessibilityIdentifier("loanPayment.principal")
        } header: {
            Text(String(localized: "Breakdown"))
        } footer: {
            Text(principal > 0
                ? String(localized: "Interest and escrow are estimated from the balance and rate. Correct them to match what your lender charged — the principal follows.")
                : String(localized: "This payment doesn't cover the interest and fees, so the balance will grow this month."))
        }
    }

    private var categorySection: some View {
        Section {
            if let category = budgetStore.pairedLoanCategory(for: account.id) {
                LabeledContent(String(localized: "Category"), value: category.name)
                    .accessibilityIdentifier("loanPayment.category")
            } else {
                LabeledContent(
                    String(localized: "Category"),
                    value: String(localized: "Not paired")
                )
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("loanPayment.category")
            }
        } footer: {
            Text(budgetStore.pairedLoanCategory(for: account.id) == nil
                ? String(localized: "Pair this loan with a category to budget for its payments. Without one the payment still records, but nothing is assigned against it.")
                : String(localized: "The whole payment is assigned to this category, while the loan balance drops by the principal alone."))
        }
    }

    private func record() {
        recording = true
        let accountId = account.id
        let fromAccountId = fundingAccountId
        let payment = self.payment
        let interest = self.interest
        let escrow = self.escrow
        let date = Transaction.yyyymmdd(from: self.date)
        Task {
            do {
                try await budgetStore.recordLoanPayment(
                    accountId: accountId,
                    fromAccountId: fromAccountId,
                    payment: payment,
                    interest: interest,
                    escrow: escrow,
                    date: date,
                    notes: nil
                )
                dismiss()
            } catch {
                budgetStore.error = error.localizedDescription
                recording = false
            }
        }
    }
}

// MARK: - Pairing

/// Pick the category a loan's payments are assigned to. Lives beside the
/// payment sheet because pairing is what makes a payment budgeted — an
/// unpaired loan records payments that nothing was assigned against.
///
/// The selection binds straight to the stored config rather than to local
/// state: `CategoryPickerView` dismisses itself on pick, and a binding that
/// writes on the way through can't disagree with what was saved. Its "None"
/// row unpairs, which is the same affordance YNAB offers.
struct LoanCategoryPairingView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    let accountId: String

    var body: some View {
        NavigationStack {
            CategoryPickerView(selectedCategoryId: Binding(
                get: { budgetStore.activeLoanConfig(for: accountId)?.categoryId },
                set: { categoryId in
                    Task { await budgetStore.pairLoan(accountId: accountId, categoryId: categoryId) }
                }
            ))
            // The title and display mode are `CategoryPickerView`'s own;
            // setting them again here only races it.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
    }
}
