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
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidAmount:
                return String(localized: "Transaction amount is missing or invalid.")
            case .noAccountAvailable:
                return String(localized: "No matching or default account available.")
            case .accountClosed:
                return String(localized: "The target account is closed.")
            case .writeFailed(let message):
                return String(localized: "Failed to save transaction: \(message)")
            }
        }
    }

    private let store: BudgetStore

    init(store: BudgetStore) {
        self.store = store
    }

    /// Logs the pending import to the budget via `TransactionLogger`.
    /// - Returns: `TransactionLogger.Result` if written successfully.
    /// - Throws: `ApproveError` if validation or writing fails.
    func approve(_ item: PendingImport) async throws -> TransactionLogger.Result {
        guard let amount = item.amount, amount > 0, amount.isFinite else {
            throw ApproveError.invalidAmount
        }

        await store.ensureBudgetReady()

        // 1. Resolve account: card hint match -> default account.
        var resolvedAccountId: String?
        if let hint = item.cardHint, !hint.isEmpty {
            resolvedAccountId = await store.resolveAccountId(hint: hint)
        }
        if resolvedAccountId == nil {
            resolvedAccountId = store.defaultAccountId
        }

        guard let accountId = resolvedAccountId else {
            throw ApproveError.noAccountAvailable
        }

        // 2. Verify account exists and is open.
        let accounts = await store.accountsForIntent()
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
                cleared: false
            )
            return result
        } catch {
            logger.error("Pending import log failed: \(error.localizedDescription, privacy: .public)")
            throw ApproveError.writeFailed(error.localizedDescription)
        }
    }
}
