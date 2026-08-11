import Foundation

/// Finds transactions that arrived via sync since the last check, so each
/// sync path (foreground or background) can notify about them exactly once.
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

    private static func watermarkKey(budgetId: String) -> String {
        "transactionNotificationWatermark.\(budgetId)"
    }

    /// Drop the watermark for a budget whose file was just downloaded. The new
    /// snapshot's messages_crdt rowids come from whichever client uploaded it,
    /// so a watermark left by a previous copy of the same budget points at
    /// unrelated messages — high enough to pass the `watermark <= maxId` guard
    /// below, low enough for the first catch-up sync to look like a pile of new
    /// transactions. Forgetting it makes the next detection re-baseline.
    static func forgetWatermark(budgetId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: watermarkKey(budgetId: budgetId))
    }

    func detectNewTransactions(in database: BudgetDatabase,
                               budgetId: String,
                               localNode: String) async throws -> [Transaction] {
        let key = Self.watermarkKey(budgetId: budgetId)
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
