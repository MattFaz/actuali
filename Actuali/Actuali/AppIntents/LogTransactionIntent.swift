import AppIntents
import Foundation

struct LogTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Transaction"
    static let description = IntentDescription(
        LocalizedStringResource("Add a transaction to your Actual budget."),
        categoryName: LocalizedStringResource("Transactions")
    )
    static let openAppWhenRun = false

    @Parameter(title: LocalizedStringResource("Budget"))
    var budget: BudgetEntity?

    @Parameter(title: LocalizedStringResource("Account"))
    var account: AccountEntity?

    @Parameter(title: LocalizedStringResource("Card or Account Hint"), default: "")
    var cardHint: String

    /// String, not Double: Wallet's amount coerces to 0 as a Number for some
    /// cards, but the text form carries the real value (issue #41). Parsed
    /// via AmountParser, which handles currency symbols and locale separators.
    @Parameter(title: LocalizedStringResource("Amount"))
    var amount: String

    @Parameter(title: LocalizedStringResource("Payee"))
    var payee: String

    @Parameter(title: LocalizedStringResource("Notes"), default: "")
    var notes: String

    /// Optional so existing shortcuts keep the payee-based auto-pick (#283).
    @Parameter(title: LocalizedStringResource("Category"))
    var category: CategoryEntity?

    @Parameter(title: LocalizedStringResource("Date"))
    var date: Date?

    @Parameter(title: LocalizedStringResource("Is Income"), default: false)
    var isIncome: Bool

    @Parameter(title: LocalizedStringResource("Cleared"), default: true)
    var cleared: Bool

    /// Siri speaks a returned dialog, but Shortcuts and Wallet automations render
    /// it as a card the user must dismiss with "Done" — which #143 turned into the
    /// normal outcome of a tap-to-pay automation. Nothing in AppIntents exposes the
    /// invocation surface, so the Siri App Shortcut opts in explicitly and every
    /// other caller stays silent; the success notification is the feedback there.
    @Parameter(title: LocalizedStringResource("Show Confirmation"), default: false)
    var showConfirmation: Bool

    init() {}

    init(showConfirmation: Bool) {
        self.showConfirmation = showConfirmation
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$payee) for \(\.$budget) in \(\.$account)") {
            \.$cardHint
            \.$notes
            \.$category
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
        if !showConfirmation {
            result.dialog = nil
        }
        return result
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await perform(using: .shared)
    }

    @MainActor
    func perform(using store: BudgetStore) async throws -> some IntentResult & ProvidesDialog {
        // Validate amount. An empty string means the automation ran before
        // Wallet had the transaction details — surface that distinctly so
        // users know it isn't a configuration problem.
        guard !amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await reportFailure(.noAmountReceived, store: store)
            throw LogTransactionError.noAmountReceived
        }
        guard let parsedAmount = AmountParser.parse(amount),
              parsedAmount.isFinite, parsedAmount > 0 else {
            await reportFailure(.invalidAmount(received: amount), store: store)
            throw LogTransactionError.invalidAmount(received: amount)
        }

        let targetBudgetId: String
        if let budget {
            do {
                targetBudgetId = try await store.localBudgetIDForIntent(budget.id)
            } catch {
                let mapped = LogTransactionError.wrapping(error)
                await reportFailure(mapped, store: store)
                throw mapped
            }
        } else {
            guard let activeBudgetId = store.currentBudgetId,
                  !(store.isConnected && activeBudgetId == DemoDataSeeder.budgetId) else {
                await reportFailure(.noBudgetLoaded, store: store)
                throw LogTransactionError.noBudgetLoaded
            }
            targetBudgetId = activeBudgetId
        }

        let writer: BudgetTransactionWriter
        do {
            // Active-budget writes reuse the existing store connection. Other
            // budgets use a cached local writer without changing app selection.
            writer = try await store.transactionWriter(for: targetBudgetId)
        } catch {
            let mapped = LogTransactionError.wrapping(error)
            await reportFailure(mapped, store: store, budgetId: targetBudgetId)
            throw mapped
        }

        do {
            let result = try await performWrite(
                using: store,
                writer: writer,
                targetBudgetId: targetBudgetId,
                parsedAmount: parsedAmount
            )
            await store.releaseTransactionWriter(for: targetBudgetId)
            return result
        } catch {
            await store.releaseTransactionWriter(for: targetBudgetId)
            throw error
        }
    }

    @MainActor
    private func performWrite(
        using store: BudgetStore,
        writer: BudgetTransactionWriter,
        targetBudgetId: String,
        parsedAmount: Double
    ) async throws -> some IntentResult & ProvidesDialog {
        // A saved account/category ID must belong to the chosen budget. Legacy
        // unscoped IDs remain valid only for shortcuts that don't choose a budget.
        let isBudgetScoped = budget != nil
        let availableAccounts = await writer.accountsForIntent()
        let cardMappings = await writer.cardMappingsForIntent()
        let resolvedAccountId: String
        if let account {
            guard let id = ScopedEntityID.rowID(
                account.id, budgetID: budget?.id ?? targetBudgetId, allowLegacyID: !isBudgetScoped
            ) else {
                await reportFailure(.accountUnavailable, store: store, budgetId: targetBudgetId, writer: writer)
                throw LogTransactionError.accountUnavailable
            }
            resolvedAccountId = id
        } else if !cardHint.isEmpty,
                  let matchedId = store.resolveAccountId(
                      hint: cardHint, accounts: availableAccounts,
                      cardMappings: cardMappings, in: targetBudgetId
                  ) {
            resolvedAccountId = matchedId
        } else if let defaultId = store.defaultAccountId(for: targetBudgetId) {
            resolvedAccountId = defaultId
        } else {
            await reportFailure(.noAccountSelected, store: store, budgetId: targetBudgetId, writer: writer)
            throw LogTransactionError.noAccountSelected
        }

        guard let activeAccount = availableAccounts.first(where: {
            $0.id == resolvedAccountId && !$0.closed
        }) else {
            await reportFailure(.accountUnavailable, store: store, budgetId: targetBudgetId, writer: writer)
            throw LogTransactionError.accountUnavailable
        }

        let categoryId: String?
        if activeAccount.offBudget {
            categoryId = nil
        } else if let category {
            let selectedID = ScopedEntityID.rowID(
                category.id, budgetID: budget?.id ?? targetBudgetId, allowLegacyID: !isBudgetScoped
            )
            guard let selectedID else {
                await reportFailure(.categoryUnavailable, store: store, budgetId: targetBudgetId, writer: writer)
                throw LogTransactionError.categoryUnavailable
            }
            let availableCategories = await writer.categoriesForIntent()
            if availableCategories.contains(where: { $0.id == selectedID }) {
                categoryId = selectedID
            } else if isBudgetScoped {
                // An explicit selection must not silently become another
                // payee-history or rules category when its category was deleted.
                await reportFailure(.categoryUnavailable, store: store, budgetId: targetBudgetId, writer: writer)
                throw LogTransactionError.categoryUnavailable
            } else {
                categoryId = nil
            }
        } else {
            categoryId = nil
        }

        // Compute signed cents.
        guard let unsigned = Transaction.cents(fromDollars: parsedAmount) else {
            await reportFailure(
                .invalidAmount(received: amount),
                store: store,
                budgetId: targetBudgetId,
                writer: writer
            )
            throw LogTransactionError.invalidAmount(received: amount)
        }
        let amountCents = isIncome ? unsigned : -unsigned

        // Delegate to logger.
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDate = date ?? Date()

        do {
            let written = try await writer.logTransaction(
                accountId: activeAccount.id,
                amountCents: amountCents,
                rawMerchant: payee,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                date: resolvedDate,
                cleared: cleared,
                categoryId: categoryId
            )

            // An inactive budget's local CRDT messages remain queued until
            // that budget is loaded by Actuali; the background refresh only
            // knows how to sync the currently active budget.
            if !written.synced, targetBudgetId == store.currentBudgetId {
                BackgroundRefresh.schedule(earliestIn: BackgroundRefresh.pendingWriteFlushInterval)
            }
            if targetBudgetId == store.currentBudgetId {
                await store.refreshAfterIntentTransaction(in: targetBudgetId)
                if let payeeId = written.payeeId {
                    store.recordPayeeLocationIfAppropriate(payeeId: payeeId)
                }
            }

            let writerCurrencyCode = await writer.currencyCode
            let writerNumberFormat = await writer.numberFormat
            let displayPayee = written.payeeName ?? payee
            await TransactionLogNotifier.notifySuccess(
                payee: displayPayee,
                amountCents: amountCents,
                currencyCode: writerCurrencyCode,
                narrowSymbol: store.useNarrowCurrencySymbol,
                synced: written.synced,
                numberFormat: writerNumberFormat,
                needsOpeningBudget: targetBudgetId != store.currentBudgetId
            )

            let amountString = CurrencyAmountFormat.string(
                cents: abs(amountCents),
                currencyCode: writerCurrencyCode,
                narrowSymbol: store.useNarrowCurrencySymbol,
                numberFormat: writerNumberFormat
            )
            let dialogText = LogTransactionDialogFormatter.string(
                amount: amountString,
                payee: displayPayee,
                synced: written.synced
            )
            return Self.result(dialogText: dialogText, showConfirmation: showConfirmation)
        } catch {
            let mapped = LogTransactionError.wrapping(error)
            await reportFailure(mapped, store: store, budgetId: targetBudgetId, writer: writer)
            throw mapped
        }
    }

    static func failurePrefillIDs(
        targetBudgetId: String?,
        activeBudgetId: String?,
        entityBudgetId: String? = nil,
        accountEntityId: String?,
        categoryEntityId: String?,
        availableAccountIDs: Set<String>,
        availableCategoryIDs: Set<String>,
        allowLegacyIDs: Bool,
        allowInactiveBudget: Bool = false
    ) -> (accountId: String?, categoryId: String?) {
        guard let targetBudgetId,
              allowInactiveBudget || targetBudgetId == activeBudgetId else {
            return (nil, nil)
        }
        let scopeBudgetId = entityBudgetId ?? targetBudgetId
        let accountId = accountEntityId
            .flatMap {
                ScopedEntityID.rowID($0, budgetID: scopeBudgetId, allowLegacyID: allowLegacyIDs)
            }
            .flatMap { availableAccountIDs.contains($0) ? $0 : nil }
        let categoryId = categoryEntityId
            .flatMap {
                ScopedEntityID.rowID($0, budgetID: scopeBudgetId, allowLegacyID: allowLegacyIDs)
            }
            .flatMap { availableCategoryIDs.contains($0) ? $0 : nil }
        return (accountId, categoryId)
    }

    @MainActor
    private func reportFailure(
        _ error: LogTransactionError,
        store: BudgetStore,
        budgetId: String? = nil,
        writer: BudgetTransactionWriter? = nil
    ) async {
        let targetBudgetId: String? = if let budgetId {
            budgetId
        } else if let budget {
            await store.localBudgetIDForFailureNotification(budget.id)
        } else {
            store.currentBudgetId
        }
        if let targetBudgetId, targetBudgetId == store.currentBudgetId {
            await store.ensureBudgetReady()
        }
        let amountCents = AmountParser.parse(amount).flatMap { Transaction.cents(fromDollars: $0) }

        // The notification now carries the destination budget and the UI
        // blocks saves until that budget is selected. Preserve the valid
        // account/category selections there instead of dropping them.
        let prefillBudgetId = targetBudgetId
        let availableAccounts: [Account]
        let availableCategories: [Category]
        if let writer {
            availableAccounts = await writer.accountsForIntent().filter { !$0.closed }
            availableCategories = await writer.categoriesForIntent()
        } else if let prefillBudgetId {
            availableAccounts = await store.accountsForIntent(in: prefillBudgetId)
                .filter { !$0.closed }
            availableCategories = await store.categoriesForIntent(in: prefillBudgetId)
        } else {
            availableAccounts = []
            availableCategories = []
        }
        let prefillIDs = Self.failurePrefillIDs(
            targetBudgetId: targetBudgetId,
            activeBudgetId: store.currentBudgetId,
            entityBudgetId: budget?.id ?? targetBudgetId,
            accountEntityId: account?.id,
            categoryEntityId: category?.id,
            availableAccountIDs: Set(availableAccounts.map(\.id)),
            availableCategoryIDs: Set(availableCategories.map(\.id)),
            allowLegacyIDs: budget == nil,
            allowInactiveBudget: budget != nil
        )
        let accountId: String?
        if account != nil {
            accountId = prefillIDs.accountId
        } else if let prefillBudgetId {
            let mapped: [String: String] = if let writer {
                await writer.cardMappingsForIntent()
            } else {
                [:]
            }
            let resolvedHint: String? = if writer != nil {
                store.resolveAccountId(
                    hint: cardHint, accounts: availableAccounts,
                    cardMappings: mapped, in: prefillBudgetId
                )
            } else {
                await store.resolveAccountId(hint: cardHint, in: prefillBudgetId)
            }
            let suggestedID = resolvedHint ?? store.defaultAccountId(for: prefillBudgetId)
            accountId = suggestedID.flatMap { id in
                availableAccounts.contains(where: { $0.id == id }) ? id : nil
            }
        } else {
            accountId = nil
        }
        let categoryId = prefillIDs.categoryId

        let currencyCode: String
        let numberFormat: ActualNumberFormat
        if let writer {
            currencyCode = await writer.currencyCode
            numberFormat = await writer.numberFormat
        } else if targetBudgetId == store.currentBudgetId {
            currencyCode = store.currencyCode
            numberFormat = store.numberFormat
        } else if let targetBudgetId {
            let preferences = await store.cachedDisplayPreferences(for: targetBudgetId)
            currencyCode = preferences.currencyCode
            numberFormat = preferences.numberFormat
        } else {
            currencyCode = store.currencyCode
            numberFormat = store.numberFormat
        }

        await TransactionLogNotifier.notifyFailure(
            message: LogTransactionError.localizedString(
                for: error, locale: .autoupdatingCurrent, bundle: .main
            ),
            payee: payee,
            amountCents: amountCents ?? 0,
            currencyCode: currencyCode,
            narrowSymbol: store.useNarrowCurrencySymbol,
            prefill: TransactionPrefill(
                accountId: accountId,
                payee: payee,
                amountCents: amountCents,
                budgetId: targetBudgetId ?? budget?.id,
                date: date ?? Date(),
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                categoryId: categoryId,
                isIncome: isIncome,
                cleared: cleared
            ),
            numberFormat: numberFormat
        )
    }
}

enum LogTransactionDialogFormatter {
    static func string(
        amount: String,
        payee: String,
        synced: Bool,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> String {
        let key = synced
            ? (payee.isEmpty ? "Logged %@" : "Logged %@ at %@")
            : (payee.isEmpty ? "Saved locally: %@" : "Saved locally: %@ at %@")
        let format = String(localized: LocalizedStringResource(
            String.LocalizationValue(key), locale: locale, bundle: bundle
        ))
        return payee.isEmpty
            ? String(format: format, amount)
            : String(format: format, amount, payee)
    }
}
