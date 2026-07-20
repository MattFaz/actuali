import Foundation

/// Finds transactions that arrived via sync since the last check, so the
/// background refresh can notify about them exactly once.
///
/// The watermark is the highest messages_crdt rowid seen at the previous
/// check, persisted per budget in UserDefaults (device-local state — it must
/// not sync). A transaction counts as new when its first CRDT message landed
/// after the watermark and was authored by another device.
struct NewTransactionDetector {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func detectNewTransactions(in database: BudgetDatabase,
                               budgetId: String,
                               localNode: String) async throws -> [Transaction] {
        let key = "transactionNotificationWatermark.\(budgetId)"
        let maxId = try await database.fetchMaxMessageId()

        guard let watermark = (defaults.object(forKey: key) as? NSNumber)?.int64Value,
              watermark <= maxId else {
            // First run, or the watermark is ahead of the database because the
            // budget file was re-downloaded (message ids reset). Baseline
            // silently rather than notifying about history.
            defaults.set(NSNumber(value: maxId), forKey: key)
            return []
        }

        guard maxId > watermark else { return [] }

        let created = try await database.fetchTransactionsCreated(
            afterMessageId: watermark, excludingNode: localNode)
        defaults.set(NSNumber(value: maxId), forKey: key)
        return created
    }
}
