import Foundation

extension BudgetStore {
    /// Restore one transaction row to its recorded earlier state.
    /// `updateTransaction` derives only the fields that actually changed, so
    /// unchanged fields do not receive a fresh HLC timestamp.
    func restoreTransaction(
        _ transaction: Transaction,
        from recordedAfter: Transaction
    ) async throws {
        try await updateTransaction(transaction, original: recordedAfter)
    }
}
