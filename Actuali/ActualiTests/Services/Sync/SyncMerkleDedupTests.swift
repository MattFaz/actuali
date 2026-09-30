import Foundation
import GRDB
import Testing
@testable import Actuali

struct SyncMerkleDedupTests {
    /// messages_crdt normally comes from the downloaded budget file, so create
    /// it with the upstream schema (timestamp UNIQUE drives the dedup).
    private func makeDatabase() async throws -> BudgetDatabase {
        try await makeTestDatabase(TestSchema.messagesCrdt).0
    }

    private func makeDatabaseWithPreferences() async throws -> BudgetDatabase {
        try await makeTestDatabase(TestSchema.preferences, TestSchema.messagesCrdt).0
    }

    private func message(millis: Int64, counter: UInt16 = 0) -> CRDTMessage {
        CRDTMessage(
            timestamp: HLCTimestamp(millis: millis, counter: counter, node: "89e0e8e90b203f9e"),
            dataset: "transactions",
            row: "row-\(millis)-\(counter)",
            column: "amount",
            value: "N:1050"
        )
    }

    private func preferenceMessage(millis: Int64, row: String, value: String) -> CRDTMessage {
        CRDTMessage(
            timestamp: HLCTimestamp(millis: millis, counter: 0, node: "89e0e8e90b203f9e"),
            dataset: "preferences",
            row: row,
            column: "value",
            value: value
        )
    }

    @Test func insertMessagesReturnsOnlyNewlyInsertedMessages() async throws {
        let database = try await makeDatabase()
        let first = message(millis: 1_700_000_000_000)
        let second = message(millis: 1_700_000_000_001)

        let initial = try database.insertMessages([first])
        #expect(initial.count == 1)

        // Server echoes `first` back alongside a genuinely new message
        let echoed = try database.insertMessages([first, second])
        #expect(echoed.count == 1)
        #expect(echoed.first?.timestamp == second.timestamp)
    }

    @Test func applyingSameMessageTwiceLeavesMerkleHashUnchanged() async throws {
        let database = try await makeDatabase()
        let msg = message(millis: 1_700_000_000_000)

        var merkle = MerkleTree()
        for inserted in try database.insertMessages([msg]) {
            merkle = merkle.inserting(inserted.timestamp)
        }
        let hashAfterFirstApply = merkle.root.hash
        #expect(hashAfterFirstApply != 0)

        // Re-applying the same message (multi-pass sync recursion, retry after
        // a failure) must not XOR the timestamp back out of the trie
        for inserted in try database.insertMessages([msg]) {
            merkle = merkle.inserting(inserted.timestamp)
        }
        #expect(merkle.root.hash == hashAfterFirstApply)
    }

    @Test func allDuplicateBatchInsertsNothing() async throws {
        let database = try await makeDatabase()
        let messages = [message(millis: 1_700_000_000_000), message(millis: 1_700_000_000_001)]

        let first = try database.insertMessages(messages)
        #expect(first.count == 2)

        let retry = try database.insertMessages(messages)
        #expect(retry.isEmpty)
    }

    @Test func emptyBatchInsertsNothing() async throws {
        let database = try await makeDatabaseWithPreferences()
        let existing = preferenceMessage(millis: 1_700_000_000_000, row: "existing", value: "S:old")
        #expect(try database.applyMessagesAndInsertMessages([existing]).count == 1)

        let before = try await database.dbQueueForTesting.read { db in
            try (
                String.fetchOne(db, sql: "SELECT value FROM preferences WHERE id = 'existing'"),
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0
            )
        }
        #expect(try database.applyMessagesAndInsertMessages([]).isEmpty)
        let after = try await database.dbQueueForTesting.read { db in
            try (
                String.fetchOne(db, sql: "SELECT value FROM preferences WHERE id = 'existing'"),
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0
            )
        }
        #expect(after.0 == before.0)
        #expect(after.1 == before.1)
    }

    @Test func atomicReceiveAppliesOnlyNewMessagesAndRollsBackOnInsertFailure() async throws {
        let database = try await makeDatabaseWithPreferences()
        let existing = preferenceMessage(millis: 1_700_000_000_000, row: "existing", value: "S:old")
        let incoming = preferenceMessage(millis: 1_700_000_000_001, row: "incoming", value: "S:new")

        _ = try database.applyMessagesAndInsertMessages([existing])
        let received = [existing, incoming]
        let newMessages = try database.filterNewMessages(received)
        #expect(newMessages.map(\.timestamp) == [incoming.timestamp])

        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
            CREATE TRIGGER fail_incoming_message_insert
            BEFORE INSERT ON messages_crdt
            WHEN NEW.timestamp = '\(incoming.timestamp.toString())'
            BEGIN
                SELECT RAISE(ABORT, 'forced message insert failure');
            END;
            """)
        }

        #expect(throws: (any Error).self) {
            try database.applyMessagesAndInsertMessages(received, applying: newMessages)
        }

        let rolledBack = try await database.dbQueueForTesting.read { db in
            try (
                String.fetchOne(db, sql: "SELECT value FROM preferences WHERE id = 'existing'"),
                String.fetchOne(db, sql: "SELECT value FROM preferences WHERE id = 'incoming'"),
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0
            )
        }
        #expect(rolledBack.0 == "old")
        #expect(rolledBack.1 == nil)
        #expect(rolledBack.2 == 1)

        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "DROP TRIGGER fail_incoming_message_insert")
        }
        let inserted = try database.applyMessagesAndInsertMessages(received, applying: newMessages)
        #expect(inserted.map(\.timestamp) == [incoming.timestamp])

        let finalState = try await database.dbQueueForTesting.read { db in
            try (
                String.fetchOne(db, sql: "SELECT value FROM preferences WHERE id = 'existing'"),
                String.fetchOne(db, sql: "SELECT value FROM preferences WHERE id = 'incoming'"),
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0
            )
        }
        #expect(finalState.0 == "old")
        #expect(finalState.1 == "new")
        #expect(finalState.2 == 2)

        let retry = try database.applyMessagesAndInsertMessages(received, applying: [])
        #expect(retry.isEmpty)
    }
}
