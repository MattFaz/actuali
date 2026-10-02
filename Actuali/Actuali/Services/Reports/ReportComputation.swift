import Foundation

/// Runs synchronous engines on the cooperative pool, preserving the card task's cancellation.
enum ReportComputation {
    @concurrent
    static func compute<Value: Sendable>(
        transactions: [Transaction],
        using compute: @Sendable ([Transaction]) -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let value = compute(transactions)
        try Task.checkCancellation()
        return value
    }
}
