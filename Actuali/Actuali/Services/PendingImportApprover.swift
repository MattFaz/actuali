import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "PendingImportApprover")

/// Service responsible for approving pending imports and writing them to the budget.
@MainActor
final class PendingImportApprover {

    enum ApproveError: LocalizedError, Equatable {
        case invalidAmount
        case noAccountAvailable
        case accountClosed
        case budgetMismatch
        case budgetIdentityRequired
        case sourceCurrencyRequired
        case sourceCurrencyMismatch(source: String, budget: String)
        case reviewConfirmationRequired
        case suppressedByRule
        case writeFailed(String)
        case alreadyApproved

        var errorDescription: String? {
            switch self {
            case .invalidAmount:
                return String(localized: "Transaction amount is missing or invalid.")
            case .noAccountAvailable:
                return String(localized: "No matching or default account available.")
            case .accountClosed:
                return String(localized: "The target account is closed.")
            case .budgetMismatch:
                return String(localized: "This import belongs to a different budget and cannot be approved here.")
            case .budgetIdentityRequired:
                return String(localized: "This import needs review before it can be approved.")
            case .sourceCurrencyRequired:
                return String(localized: "This import needs review before it can be approved.")
            case .sourceCurrencyMismatch(let source, let budget):
                return String(localized: "This import is in \(source), but the active budget uses \(budget). Review and confirm the transaction before saving.")
            case .reviewConfirmationRequired:
                return String(localized: "Review and confirm this import before saving it.")
            case .suppressedByRule:
                return String(localized: "A transaction rule suppressed this import, so it remains pending.")
            case .writeFailed(let message):
                return String(localized: "Failed to save transaction: \(message)")
            case .alreadyApproved:
                return String(localized: "This pending import was already saved.")
            }
        }
    }

    private let store: BudgetStore

    init(store: BudgetStore) {
        self.store = store
    }

    /// Resolves an account for direct approval. Automatic approval is only
    /// allowed when the card mapping or explicit default is trustworthy.
    nonisolated static func resolveAccountId(
        cardHint: String?,
        accounts: [Account],
        cardMappings: [String: String],
        defaultAccountId: String?
    ) -> String? {
        if let hint = cardHint, !hint.isEmpty,
           let resolved = BudgetStore.resolveAccountId(
               hint: hint, accounts: accounts, cardMappings: cardMappings) {
            return resolved
        }
        if let defaultAccountId,
           accounts.contains(where: { $0.id == defaultAccountId && !$0.closed }) {
            return defaultAccountId
        }
        return nil
    }

    /// Seeds the editor with a usable open account when strict automatic
    /// approval cannot choose one. The user can inspect and change this value.
    nonisolated static func seedAccountId(
        cardHint: String?,
        accounts: [Account],
        cardMappings: [String: String],
        defaultAccountId: String?
    ) -> String? {
        resolveAccountId(
            cardHint: cardHint,
            accounts: accounts,
            cardMappings: cardMappings,
            defaultAccountId: defaultAccountId
        ) ?? accounts.first(where: { !$0.closed })?.id
    }

    /// Logs the pending import to the budget via `TransactionLogger`.
    /// - Returns: `TransactionLogger.Result` if written successfully.
    /// - Throws: `ApproveError` if validation or writing fails.
    func approve(_ item: PendingImport) async throws -> TransactionLogger.Result {
        guard let amount = item.amount, amount > 0, amount.isFinite else {
            throw ApproveError.invalidAmount
        }

        guard let currentBudgetId = store.currentBudgetId else {
            throw ApproveError.budgetIdentityRequired
        }
        guard let originBudgetId = item.originBudgetId else {
            throw ApproveError.budgetIdentityRequired
        }
        guard originBudgetId == currentBudgetId else {
            throw ApproveError.budgetMismatch
        }

        await store.ensureBudgetReady()

        guard let sourceCurrencyCode = item.sourceCurrencyCode else {
            throw ApproveError.sourceCurrencyRequired
        }
        let normalizedSourceCurrency = PendingImport.normalizedCurrencyCode(sourceCurrencyCode)
        let normalizedBudgetCurrency = PendingImport.normalizedCurrencyCode(store.currencyCode)
        if normalizedSourceCurrency != normalizedBudgetCurrency {
            throw ApproveError.sourceCurrencyMismatch(
                source: normalizedSourceCurrency,
                budget: normalizedBudgetCurrency
            )
        }

        // 1. Resolve account using the same chain as the edit form.
        let accounts = await store.accountsForIntent()
        let resolvedAccountId = Self.resolveAccountId(
            cardHint: item.cardHint,
            accounts: accounts,
            cardMappings: store.cardAccountMappings,
            defaultAccountId: store.defaultAccountId
        )

        guard let accountId = resolvedAccountId else {
            throw ApproveError.noAccountAvailable
        }

        // 2. Verify account exists and is open.
        guard let account = accounts.first(where: { $0.id == accountId }) else {
            throw ApproveError.noAccountAvailable
        }
        guard !account.closed else {
            throw ApproveError.accountClosed
        }

        // 3. Convert to signed cents.
        guard let unsignedCents = Transaction.cents(fromDollars: amount) else {
            throw ApproveError.invalidAmount
        }
        let amountCents = item.isIncome ? unsignedCents : -unsignedCents

        // 4. Log transaction.
        do {
            let result = try await TransactionLogger(store: store).logTransaction(
                accountId: account.id,
                amountCents: amountCents,
                rawMerchant: item.payee ?? "Unknown",
                notes: nil,
                date: item.date,
                // Uncleared until the user reconciles: parsed messages aren't
                // bank-confirmed. Matches upstream Actual, where manual entries
                // start uncleared and bank sync sets cleared from `booked`.
                cleared: false,
                financialId: Self.financialId(for: item),
                transactionId: item.id.uuidString
            )
            return result
        } catch TransactionLogger.LoggerError.transactionAlreadyExists {
            throw ApproveError.alreadyApproved
        } catch TransactionLogger.LoggerError.transactionSuppressedByRule {
            throw ApproveError.suppressedByRule
        } catch TransactionLogger.LoggerError.transactionNeedsRecovery {
            throw ApproveError.writeFailed("This import needs review before it can be approved.")
        } catch {
            logger.error("Pending import log failed: \(error.localizedDescription, privacy: .public)")
            throw ApproveError.writeFailed(error.localizedDescription)
        }
    }

    /// Saves the standard transaction produced by the pending-import editor.
    /// The deterministic financial id makes a retry after queue cleanup fails
    /// a successful no-op instead of a second transaction.
    func saveEdited(_ item: PendingImport, form: BudgetStore.TransactionForm) async throws -> SaveResult {
        guard form.type != .transfer, form.splits.isEmpty,
              let amount = Double(form.amount),
              let unsignedCents = Transaction.cents(fromDollars: amount),
              unsignedCents > 0 else {
            throw ApproveError.invalidAmount
        }
        guard let currentBudgetId = store.currentBudgetId else {
            throw ApproveError.budgetIdentityRequired
        }
        let reviewRequirements = item.reviewRequirements(
            activeBudgetId: currentBudgetId,
            budgetCurrency: store.currencyCode
        )
        if !reviewRequirements.isEmpty
            && !form.reviewConfirmations.isSuperset(of: reviewRequirements) {
            throw ApproveError.reviewConfirmationRequired
        }

        await store.ensureBudgetReady()
        let accounts = await store.accountsForIntent()
        guard let account = accounts.first(where: { $0.id == form.accountId }) else {
            throw ApproveError.noAccountAvailable
        }
        guard !account.closed else { throw ApproveError.accountClosed }

        let financialId = Self.financialId(for: item)
        guard store.databaseForLogger != nil else {
            throw TransactionLogger.LoggerError.noBudgetLoaded
        }
        let payeeName = form.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let payee = payeeName.isEmpty ? nil : try await store.findOrCreatePayee(name: payeeName)
        let transaction = Transaction(
            id: item.id.uuidString,
            accountId: account.id,
            date: Transaction.yyyymmdd(from: form.date),
            amount: form.type == .income ? unsignedCents : -unsignedCents,
            payeeId: payee?.id,
            payeeName: payee?.name,
            categoryId: form.categoryId,
            categoryName: nil,
            notes: form.notes.isEmpty ? nil : form.notes,
            cleared: form.cleared,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: payeeName.isEmpty ? nil : form.payeeName,
            financialId: financialId
        )
        switch try await store.createTransaction(transaction) {
        case .inserted(let id): return .inserted(id)
        case .duplicate: return .duplicate
        case .suppressedByRule: return .suppressedByRule
        }
    }

    enum SaveResult: Equatable {
        case inserted(String)
        case duplicate
        case suppressedByRule
    }

    nonisolated static func financialId(for item: PendingImport) -> String {
        "actuali-pending-import:\(item.id.uuidString.lowercased())"
    }
}
