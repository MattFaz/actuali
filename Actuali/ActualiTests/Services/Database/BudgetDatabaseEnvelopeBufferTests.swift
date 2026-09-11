import Foundation
import Testing
import GRDB
@testable import Actuali

struct BudgetDatabaseEnvelopeBufferTests {
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("buffer-\(UUID().uuidString).sqlite")
        try DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE zero_budget_months (
                    id TEXT PRIMARY KEY,
                    buffered INTEGER NOT NULL DEFAULT 0
                )
                """)
        }
        return (try BudgetDatabase(path: url), url)
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
    func createsMissingRow() throws {
        let (database, path) = try makeDatabase()
        try database.applyMessagesAndInsertMessages([
            message(amount: 500, millis: 1_700_000_000_000)
        ])

        #expect(try bufferedValue(path: path) == 500)
        #expect(try storedMessageCount(path: path) == 1)
    }

    @Test("Buffer CRDT message updates an existing zero-budget row")
    func updatesExistingRow() throws {
        let (database, path) = try makeDatabase()
        try database.applyMessagesAndInsertMessages([
            message(amount: 500, millis: 1_700_000_000_000)
        ])
        try database.applyMessagesAndInsertMessages([
            message(amount: 250, millis: 1_700_000_000_001)
        ])

        #expect(try bufferedValue(path: path) == 250)
        #expect(try storedMessageCount(path: path) == 2)
    }

    @Test("Reset buffer writes zero to the synced row")
    func resetsExistingRow() throws {
        let (database, path) = try makeDatabase()
        try database.applyMessagesAndInsertMessages([
            message(amount: 500, millis: 1_700_000_000_000)
        ])
        try database.applyMessagesAndInsertMessages([
            message(amount: 0, millis: 1_700_000_000_001)
        ])

        #expect(try bufferedValue(path: path) == 0)
        #expect(try storedMessageCount(path: path) == 2)
    }

    @Test("Latest buffer CRDT message wins regardless of application order")
    func latestMessageWinsOutOfOrder() throws {
        let earlier = message(amount: 500, millis: 1_700_000_000_000)
        let later = message(amount: 250, millis: 1_700_000_000_001)

        let (orderedDatabase, orderedPath) = try makeDatabase()
        try orderedDatabase.applyMessagesAndInsertMessages([earlier, later])

        let (reversedDatabase, reversedPath) = try makeDatabase()
        try reversedDatabase.applyMessagesAndInsertMessages([later, earlier])

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
