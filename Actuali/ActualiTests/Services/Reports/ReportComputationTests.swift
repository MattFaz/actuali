import Foundation
import Testing
@testable import Actuali

@MainActor
struct ReportComputationTests {
    @Test func computationLeavesMainActorAndPreservesOutput() async throws {
        let expected = MonteCarloEngine.compute(meta: nil, accountBalances: ["checking": 12345])
        let result = try await ReportComputation.compute(transactions: []) { transactions in
            #expect(!Thread.isMainThread)
            #expect(transactions.isEmpty)
            return MonteCarloEngine.compute(meta: nil, accountBalances: ["checking": 12345])
        }
        #expect(result == expected)
    }

    @Test func cancelledTaskDoesNotStartComputation() async {
        let task = Task {
            try await ReportComputation.compute(transactions: []) { _ in
                Issue.record("Cancelled computation must not start")
                return 1
            }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellationDuringComputationDiscardsResult() async {
        let task = Task {
            try await ReportComputation.compute(transactions: []) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return 42
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
