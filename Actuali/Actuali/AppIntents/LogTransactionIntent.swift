import AppIntents
import Foundation

struct LogTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Transaction"
    static let description = IntentDescription(
        "Add a transaction to your Actual budget.",
        categoryName: "Transactions"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Account")
    var account: AccountEntity?

    // String, not Double: Wallet's amount coerces to 0 as a Number for some
    // cards, but the text form carries the real value (issue #41). Parsed
    // via AmountParser, which handles currency symbols and locale separators.
    @Parameter(title: "Amount")
    var amount: String

    @Parameter(title: "Payee")
    var payee: String

    @Parameter(title: "Notes", default: "")
    var notes: String

    @Parameter(title: "Date")
    var date: Date?

    @Parameter(title: "Is Income", default: false)
    var isIncome: Bool

    @Parameter(title: "Cleared", default: true)
    var cleared: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$payee) in \(\.$account)") {
            \.$notes
            \.$date
            \.$isIncome
            \.$cleared
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Validate amount. An empty string means the automation ran before
        // Wallet had the transaction details — surface that distinctly so
        // users know it isn't a configuration problem.
        guard !amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await reportFailure(.noAmountReceived)
            throw LogTransactionError.noAmountReceived
        }
        guard let parsedAmount = AmountParser.parse(amount),
              parsedAmount.isFinite, parsedAmount > 0 else {
            await reportFailure(.invalidAmount)
            throw LogTransactionError.invalidAmount
        }

        // Resolve account: explicit parameter, else defaultAccountId, else error.
        let store = BudgetStore.shared
        // Headless launch (openAppWhenRun = false) can reach the write path before
        // init()'s background load has wired syncClient; wait for it so the write
        // doesn't fail with "Sync not configured".
        await store.ensureBudgetReady()
        let resolvedAccountId: String
        if let account {
            resolvedAccountId = account.id
        } else if let defaultId = store.defaultAccountId {
            resolvedAccountId = defaultId
        } else {
            await reportFailure(.noBudgetLoaded)
            throw LogTransactionError.noBudgetLoaded
        }

        // Verify the account still exists and is open. Use accountsForIntent()
        // so this works on a cold headless launch where the in-memory cache is
        // not yet populated.
        let availableAccounts = await store.accountsForIntent()
        guard let activeAccount = availableAccounts.first(where: { $0.id == resolvedAccountId && !$0.closed }) else {
            await reportFailure(.accountUnavailable)
            throw LogTransactionError.accountUnavailable
        }

        // Compute signed cents.
        guard let unsigned = Transaction.cents(fromDollars: parsedAmount) else {
            await reportFailure(.invalidAmount)
            throw LogTransactionError.invalidAmount
        }
        let amountCents = isIncome ? unsigned : -unsigned

        // Delegate to logger.
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDate = date ?? Date()

        do {
            let written = try await TransactionLogger(store: .shared).logTransaction(
                accountId: activeAccount.id,
                amountCents: amountCents,
                rawMerchant: payee,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                date: resolvedDate,
                cleared: cleared
            )

            let displayPayee = written.payeeName ?? payee
            await TransactionLogNotifier.notifySuccess(
                payee: displayPayee,
                amountCents: amountCents,
                currencyCode: store.currencyCode
            )
            return .result()
        } catch {
            let mapped: LogTransactionError = (error as? LogTransactionError)
                ?? .writeFailed(underlying: error.localizedDescription)
            await reportFailure(mapped)
            throw mapped
        }
    }

    @MainActor
    private func reportFailure(_ error: LogTransactionError) async {
        let amountCents = AmountParser.parse(amount).flatMap { Transaction.cents(fromDollars: $0) }
        await TransactionLogNotifier.notifyFailure(
            message: error.errorDescription ?? "Unknown error",
            payee: payee,
            amountCents: amountCents ?? 0,
            prefill: TransactionPrefill(
                accountId: account?.id ?? BudgetStore.shared.defaultAccountId,
                payee: payee,
                amountCents: amountCents,
                date: date ?? Date()
            )
        )
    }
}
