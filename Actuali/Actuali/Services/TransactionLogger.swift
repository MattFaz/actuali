import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "TransactionLogger")

/// Headless transaction-write service used by `LogTransactionIntent`.
/// Normalizes the merchant string, matches-or-creates the payee, infers a
/// category from the most recent prior transaction at that payee, and writes
/// via `BudgetStore.createTransaction`.
@MainActor
final class TransactionLogger {

    enum LoggerError: LocalizedError {
        case noBudgetLoaded

        var errorDescription: String? {
            switch self {
            case .noBudgetLoaded:
                return "Open Actuali and select a budget first."
            }
        }
    }

    /// The written row plus whether it reached the server. `synced == false`
    /// means it is queued locally for the next successful sync, which in the
    /// headless intent path may not happen until the app is opened (issue #139).
    struct Result {
        let transaction: Transaction
        let synced: Bool
    }

    private let store: BudgetStore

    init(store: BudgetStore) {
        self.store = store
    }

    /// - Parameters:
    ///   - accountId: target Actual account id
    ///   - amountCents: signed amount in cents (negative = outflow)
    ///   - rawMerchant: merchant string from Wallet/Shortcuts (un-normalized)
    ///   - notes: optional notes from the caller
    ///   - date: transaction date
    ///   - cleared: whether the transaction is marked cleared in Actual
    /// - Returns: the written transaction and whether it reached the server
    func logTransaction(
        accountId: String,
        amountCents: Int,
        rawMerchant: String,
        notes: String?,
        date: Date,
        cleared: Bool = true
    ) async throws -> Result {
        guard let database = store.databaseForLogger else {
            throw LoggerError.noBudgetLoaded
        }

        let normalized = MerchantNormalizer.normalize(rawMerchant)
        let payeeName = normalized.isEmpty ? rawMerchant : normalized
        let payee = try await store.findOrCreatePayee(name: payeeName)

        let categoryId = try await database.mostRecentCategoryId(forPayeeId: payee.id)

        // Use the un-normalized merchant string as imported_payee so user rules
        // like "imported_payee CONTAINS X" can match the original bank text.
        let importedPayee = rawMerchant.isEmpty ? payeeName : rawMerchant

        let transaction = Transaction(
            id: UUID().uuidString,
            accountId: accountId,
            date: Transaction.yyyymmdd(from: date),
            amount: amountCents,
            payeeId: payee.id,
            payeeName: payee.name,
            categoryId: categoryId,
            categoryName: nil,
            notes: notes,
            cleared: cleared,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: importedPayee
        )

        try await store.createTransaction(transaction)
        // With when-in-use permission, background automations get no fix and silently skip.
        store.recordPayeeLocationIfAppropriate(payeeId: payee.id)
        // Writes push in the background so the UI never waits on the network
        // (issue #125), but an App Intent runs headless and can be frozen the
        // moment it returns — wait for the push here so a Siri/Shortcuts log
        // still reaches the server before that happens.
        await store.flushPendingSync()
        // The push is detached, so it can't report its own outcome: ask the
        // queue instead. Anything still pending here means the server wasn't
        // reachable and the row lives only on this device (issue #139).
        let synced = !(await store.hasPendingLocalWrites())
        logger.info("Logged transaction \(transaction.id, privacy: .public) for \(payee.name, privacy: .public), synced: \(synced, privacy: .public)")
        return Result(transaction: transaction, synced: synced)
    }
}
