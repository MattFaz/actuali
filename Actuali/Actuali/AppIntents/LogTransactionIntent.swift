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

    @Parameter(title: "Card or Account Hint", default: "")
    var cardHint: String

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

    // Siri speaks a returned dialog, but Shortcuts and Wallet automations render
    // it as a card the user must dismiss with "Done" — which #143 turned into the
    // normal outcome of a tap-to-pay automation. Nothing in AppIntents exposes the
    // invocation surface, so the Siri App Shortcut opts in explicitly and every
    // other caller stays silent; the success notification is the feedback there.
    @Parameter(title: "Show Confirmation", default: false)
    var showConfirmation: Bool

    init() {}

    init(showConfirmation: Bool) {
        self.showConfirmation = showConfirmation
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$payee) in \(\.$account)") {
            \.$cardHint
            \.$notes
            \.$date
            \.$isIncome
            \.$cleared
            \.$showConfirmation
        }
    }

    nonisolated static func result(
        dialogText: String,
        showConfirmation: Bool
    ) -> IntentResultContainer<Never, Never, Never, IntentDialog> {
        var result = IntentResultContainer<Never, Never, Never, IntentDialog>
            .result(dialog: IntentDialog(stringLiteral: dialogText))
        if !showConfirmation { result.dialog = nil }
        return result
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Validate amount. An empty string means the automation ran before
        // Wallet had the transaction details — surface that distinctly so
        // users know it isn't a configuration problem.
        guard !amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await reportFailure(.noAmountReceived)
            throw LogTransactionError.noAmountReceived
        }
        guard let parsedAmount = AmountParser.parse(amount),
              parsedAmount.isFinite, parsedAmount > 0 else {
            await reportFailure(.invalidAmount(received: amount))
            throw LogTransactionError.invalidAmount(received: amount)
        }

        // Resolve account: explicit parameter, else defaultAccountId, else error.
        let store = BudgetStore.shared
        // Headless launch (openAppWhenRun = false) can reach the write path before
        // init()'s background load has wired syncClient; wait for it so the write
        // doesn't fail with "Sync not configured".
        await store.ensureBudgetReady()

        guard store.currentBudgetId != nil else {
            await reportFailure(.noBudgetLoaded)
            throw LogTransactionError.noBudgetLoaded
        }

        let resolvedAccountId: String
        if let account {
            resolvedAccountId = account.id
        } else if !cardHint.isEmpty, let matchedId = await store.resolveAccountId(hint: cardHint) {
            resolvedAccountId = matchedId
        } else if let defaultId = store.defaultAccountId {
            resolvedAccountId = defaultId
        } else {
            await reportFailure(.noAccountSelected)
            throw LogTransactionError.noAccountSelected
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
            await reportFailure(.invalidAmount(received: amount))
            throw LogTransactionError.invalidAmount(received: amount)
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

            // The row is safely on disk either way, but an unreachable server
            // means it only exists here. Say so rather than reporting a plain
            // success, and ask iOS for an early wake so the queued write has a
            // chance to land before the app is next opened (issue #139).
            if !written.synced {
                BackgroundRefresh.schedule(earliestIn: BackgroundRefresh.pendingWriteFlushInterval)
            }

            let displayPayee = written.transaction.payeeName ?? payee
            await TransactionLogNotifier.notifySuccess(
                payee: displayPayee,
                amountCents: amountCents,
                currencyCode: store.currencyCode,
                narrowSymbol: store.useNarrowCurrencySymbol,
                synced: written.synced
            )

            let amountString = CurrencyAmountFormat.string(
                cents: abs(amountCents),
                currencyCode: store.currencyCode,
                narrowSymbol: store.useNarrowCurrencySymbol
            )
            let verb = written.synced ? "Logged" : "Saved locally:"
            let dialogText = displayPayee.isEmpty
                ? "\(verb) \(amountString)"
                : "\(verb) \(amountString) at \(displayPayee)"
            return Self.result(dialogText: dialogText, showConfirmation: showConfirmation)
        } catch {
            let mapped: LogTransactionError = (error as? LogTransactionError)
                ?? .writeFailed(underlying: error.localizedDescription)
            await reportFailure(mapped)
            throw mapped
        }
    }

    @MainActor
    private func reportFailure(_ error: LogTransactionError) async {
        let store = BudgetStore.shared
        await store.ensureBudgetReady()
        let amountCents = AmountParser.parse(amount).flatMap { Transaction.cents(fromDollars: $0) }
        await TransactionLogNotifier.notifyFailure(
            message: error.errorDescription ?? "Unknown error",
            payee: payee,
            amountCents: amountCents ?? 0,
            currencyCode: store.currencyCode,
            narrowSymbol: store.useNarrowCurrencySymbol,
            prefill: TransactionPrefill(
                accountId: account?.id ?? store.defaultAccountId,
                payee: payee,
                amountCents: amountCents,
                date: date ?? Date(),
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                isIncome: isIncome,
                cleared: cleared
            )
        )
    }
}
