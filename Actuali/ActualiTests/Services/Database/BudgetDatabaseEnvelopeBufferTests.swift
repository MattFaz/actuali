import Foundation
import GRDB
import Testing
@testable import Actuali

struct BudgetDatabaseEnvelopeBufferTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.accounts, TestSchema.messagesCrdt, TestSchema.zeroBudgetMonths)
    }

    private func message(amount: Int, millis: Int64) -> CRDTMessage {
        CRDTMessage(
            timestamp: HLCTimestamp(millis: millis, counter: 0, node: "buffer-test-node"),
            dataset: "zero_budget_months",
            row: "2026-09",
            column: "buffered",
            value: CRDTValue.serialize(amount)
        )
    }

    private func bufferedValue(path: URL) throws -> Int? {
        try DatabaseQueue(path: path.path).read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT buffered FROM zero_budget_months WHERE id = ?",
                arguments: ["2026-09"]
            )
        }
    }

    private func storedMessageCount(path: URL) throws -> Int {
        try DatabaseQueue(path: path.path).read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM messages_crdt
                WHERE dataset = ? AND row = ? AND column = ?
                """,
                arguments: ["zero_budget_months", "2026-09", "buffered"]
            ) ?? 0
        }
    }

    @Test("Buffer CRDT message creates a missing zero-budget row")
    func createsMissingRow() async throws {
        let (database, path) = try await makeDatabase()
        _ = try database.applyMessagesAndInsertMessages([
            message(amount: 500, millis: 1_700_000_000_000),
        ])

        #expect(try bufferedValue(path: path) == 500)
        #expect(try storedMessageCount(path: path) == 1)
    }

    @Test("Buffer CRDT message updates an existing zero-budget row")
    func updatesExistingRow() async throws {
        let (database, path) = try await makeDatabase()
        _ = try database.applyMessagesAndInsertMessages([
            message(amount: 500, millis: 1_700_000_000_000),
        ])
        _ = try database.applyMessagesAndInsertMessages([
            message(amount: 250, millis: 1_700_000_000_001),
        ])

        #expect(try bufferedValue(path: path) == 250)
        #expect(try storedMessageCount(path: path) == 2)
    }

    @Test("Reset buffer writes zero to the synced row")
    func resetsExistingRow() async throws {
        let (database, path) = try await makeDatabase()
        _ = try database.applyMessagesAndInsertMessages([
            message(amount: 500, millis: 1_700_000_000_000),
        ])
        _ = try database.applyMessagesAndInsertMessages([
            message(amount: 0, millis: 1_700_000_000_001),
        ])

        #expect(try bufferedValue(path: path) == 0)
        #expect(try storedMessageCount(path: path) == 2)
    }

    @Test("Latest buffer CRDT message wins regardless of application order")
    func latestMessageWinsOutOfOrder() async throws {
        let earlier = message(amount: 500, millis: 1_700_000_000_000)
        let later = message(amount: 250, millis: 1_700_000_000_001)

        let (orderedDatabase, orderedPath) = try await makeDatabase()
        _ = try orderedDatabase.applyMessagesAndInsertMessages([earlier, later])

        let (reversedDatabase, reversedPath) = try await makeDatabase()
        _ = try reversedDatabase.applyMessagesAndInsertMessages([later, earlier])

        #expect(try bufferedValue(path: orderedPath) == 250)
        #expect(try bufferedValue(path: reversedPath) == 250)
    }

    @Test("Message generator produces an Actual-compatible buffer message")
    func messageGeneratorProducesBufferMessage() async throws {
        let generator = MessageGenerator(clock: HybridLogicalClock(node: "buffer-test-node"))
        let messages = try await generator.messages(
            dataset: "zero_budget_months",
            row: "2026-09",
            fields: [("buffered", 500)]
        )

        #expect(messages.count == 1)
        #expect(messages[0].dataset == "zero_budget_months")
        #expect(messages[0].row == "2026-09")
        #expect(messages[0].column == "buffered")
        #expect(!messages[0].timestamp.toString().isEmpty)
    }
}
