import Foundation
import Testing
import GRDB
@testable import Actuali

struct SyncMerkleDedupTests {

    /// messages_crdt normally comes from the downloaded budget file, so create
    /// it with the upstream schema (timestamp UNIQUE drives the dedup).
    private func makeDatabase() throws -> BudgetDatabase {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
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
        }
        return try BudgetDatabase(path: tempURL)
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

    @Test func insertMessagesReturnsOnlyNewlyInsertedMessages() throws {
        let database = try makeDatabase()
        let first = message(millis: 1_700_000_000_000)
        let second = message(millis: 1_700_000_000_001)

        let initial = try database.insertMessages([first])
        #expect(initial.count == 1)

        // Server echoes `first` back alongside a genuinely new message
        let echoed = try database.insertMessages([first, second])
        #expect(echoed.count == 1)
        #expect(echoed.first?.timestamp == second.timestamp)
    }

    @Test func applyingSameMessageTwiceLeavesMerkleHashUnchanged() throws {
        let database = try makeDatabase()
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

    @Test func allDuplicateBatchInsertsNothing() throws {
        let database = try makeDatabase()
        let messages = [message(millis: 1_700_000_000_000), message(millis: 1_700_000_000_001)]

        let first = try database.insertMessages(messages)
        #expect(first.count == 2)

        let retry = try database.insertMessages(messages)
        #expect(retry.isEmpty)
    }

    @Test func emptyBatchInsertsNothing() throws {
        let database = try makeDatabase()
        #expect(try database.insertMessages([]).isEmpty)
    }
}
