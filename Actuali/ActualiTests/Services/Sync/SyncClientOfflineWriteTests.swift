import Foundation
import GRDB
import Testing
@testable import Actuali

/// A server that accepts the connection and then never answers in time — what
/// an unreachable self-hosted server looks like to URLSession (the request
/// hangs until the timeout rather than failing fast).
private final class StallingSyncTransport: URLProtocol {
    /// Seconds each request stalls before failing. Long enough that awaiting
    /// it is unmistakable in a timing assertion, short enough not to wedge the
    /// suite.
    static let stall: TimeInterval = 3

    private static let lock = NSLock()
    nonisolated(unsafe) private static var attempts = 0

    static func resetAttempts() {
        lock.withLock { attempts = 0 }
    }

    static var attemptCount: Int {
        lock.withLock { attempts }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.attempts += 1 }
        Thread.sleep(forTimeInterval: Self.stall)
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}

/// Issue #125: adding a transaction hung for the full network timeout when the
/// server was unreachable. The row and its CRDT messages are committed locally
/// before the push, so the push must not be awaited by the caller — the write
/// returns immediately and the sync is deferred to the retry ladder.
@Suite(.serialized)
struct SyncClientOfflineWriteTests {

    /// transactions and messages_crdt normally come from the downloaded budget
    /// file, so create them with the upstream schema.
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    starting_balance_flag INTEGER DEFAULT 0,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    acct TEXT,
                    category TEXT,
                    amount INTEGER,
                    description TEXT,
                    notes TEXT,
                    date INTEGER,
                    imported_description TEXT,
                    financial_id TEXT,
                    transferred_id TEXT,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    parent_id TEXT
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
                CREATE TABLE rules (
                    id TEXT PRIMARY KEY,
                    stage TEXT,
                    conditions TEXT,
                    actions TEXT,
                    tombstone INTEGER DEFAULT 0,
                    conditions_op TEXT DEFAULT 'and'
                )
                """)
            try db.execute(sql: """
                CREATE TABLE payee_mapping (
                    id TEXT PRIMARY KEY,
                    targetId TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE payees (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    transfer_acct TEXT,
                    tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    offbudget INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    cat_group TEXT,
                    tombstone INTEGER DEFAULT 0
                )
                """)
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    /// Sync client whose every request stalls, standing in for a server that
    /// is down or off-network.
    private func makeSyncClient(database: BudgetDatabase) async throws -> SyncClient {
        StallingSyncTransport.resetAttempts()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StallingSyncTransport.self]
        let serverClient = ActualServerClient(session: URLSession(configuration: config))
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("test-token")

        let syncClient = SyncClient(serverClient: serverClient, nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        return syncClient
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func transaction(id: String) -> Transaction {
        Transaction(
            id: id,
            accountId: "acct-1",
            date: 20260811,
            amount: -1234,
            payeeId: "payee-1",
            payeeName: "Coffee",
            categoryId: "cat-1",
            categoryName: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )
    }

    private func rowExists(_ database: BudgetDatabase, id: String) throws -> Bool {
        try database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions WHERE id = ?", arguments: [id]) ?? 0
        } > 0
    }

    /// The whole bug: the caller must not wait on the network round trip.
    @Test func createTransactionReturnsWithoutWaitingForTheServer() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        let start = Date()
        try await syncClient.createTransaction(transaction(id: "tx-offline-1"))
        let elapsed = Date().timeIntervalSince(start)

        // Bounded by the stall, not a fixed budget: a caller that awaited the
        // push can't return before the stall elapses, while a loaded CI runner
        // can take well over a second just to get the first write through.
        #expect(elapsed < StallingSyncTransport.stall, "createTransaction blocked for \(elapsed)s waiting on an unreachable server")
        // Local-first: the transaction is already durable on return.
        #expect(try rowExists(database, id: "tx-offline-1"))
    }

    /// Deferred, not dropped: the push still goes out, just off the caller's
    /// thread.
    @Test func pushStillHappensAfterTheWriteReturns() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.createTransaction(transaction(id: "tx-offline-2"))

        var observed = StallingSyncTransport.attemptCount
        for _ in 0..<40 where observed == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
            observed = StallingSyncTransport.attemptCount
        }
        #expect(observed >= 1, "the deferred sync never reached the server")
    }

    @Test func transactionUpdateRollsBackWhenMessagePersistenceFails() throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        let original = transaction(id: "tx-atomic-update")
        try database.insertTransaction(original)
        var updated = original
        updated.amount = -9999

        try database.dbQueueForTesting.write { db in
            try db.execute(sql: "DROP TABLE messages_crdt")
        }

        let message = CRDTMessage(
            timestamp: HLCTimestamp(millis: 1_700_000_000_000, counter: 0, node: "89e0e8e90b203f9e"),
            dataset: "transactions",
            row: updated.id,
            column: "amount",
            value: "N:-9999"
        )
        #expect(throws: (any Error).self) {
            try database.updateTransactionWithMessages(updated, messages: [message])
        }

        let amount = try database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT amount FROM transactions WHERE id = ?", arguments: [updated.id])
        }
        #expect(amount == original.amount)
    }

    @Test func bulkTransactionUpdateRollsBackEveryRowWhenMessagePersistenceFails() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let first = transaction(id: "tx-bulk-1")
        let second = transaction(id: "tx-bulk-2")
        try database.insertTransaction(first)
        try database.insertTransaction(second)
        let syncClient = try await makeSyncClient(database: database)

        var firstUpdate = first
        firstUpdate.amount = -2000
        var secondUpdate = second
        secondUpdate.amount = -3000
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "DROP TABLE messages_crdt")
        }

        await #expect(throws: (any Error).self) {
            try await syncClient.updateTransactions(
                [firstUpdate, secondUpdate], changedFields: ["amount"])
        }

        let amounts = try await database.dbQueueForTesting.read { db in
            try Int.fetchAll(db, sql: "SELECT amount FROM transactions ORDER BY id")
        }
        #expect(amounts == [first.amount, second.amount])
    }

    @Test func financialIdRetryReturnsDuplicateWithoutChangingMessagesOrMerkle() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)
        let imported: Transaction = {
            var value = transaction(id: "tx-retry")
            value.financialId = "financial-retry"
            return value
        }()
        let importedId = imported.id

        let firstResult = try await syncClient.createTransaction(imported, applyRules: true)
        #expect(firstResult == .inserted("tx-retry"))
        let firstMessages = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE row = ?", arguments: [importedId]) ?? 0
        }
        let firstMerkle = try database.deriveMerkleFromMessageLog().root.hash

        let retryResult = try await syncClient.createTransaction(imported, applyRules: true)
        #expect(retryResult == .duplicate)
        let secondMessages = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE row = ?", arguments: [importedId]) ?? 0
        }
        #expect(secondMessages == firstMessages)
        #expect(try database.deriveMerkleFromMessageLog().root.hash == firstMerkle)
    }

    @Test func zeroMessageFinancialIdRetryRepairsThroughSyncClient() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)
        let imported: Transaction = {
            var value = transaction(id: "tx-zero-message")
            value.financialId = "financial-zero-message"
            return value
        }()
        try database.insertTransaction(imported)

        let result = try await syncClient.createTransaction(imported, applyRules: true)
        #expect(result == .inserted("tx-zero-message"))
        let messageCount = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE row = ?", arguments: [imported.id]) ?? 0
        }
        #expect(messageCount == imported.syncableFields.count)
        #expect(try database.deriveMerkleFromMessageLog().root.hash != MerkleTree().root.hash)
    }

    @Test func zeroMessageRepairPersistsRuleMutationInRowAndMessages() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO rules (id, conditions, actions, tombstone, conditions_op)
                VALUES ('set-rule-note',
                    '[{"op":"contains","field":"imported_description","value":"Coffee"}]',
                    '[{"op":"set","field":"notes","value":"Rule note"}]', 0, 'and')
                """)
        }

        let imported: Transaction = {
            var value = transaction(id: "tx-rule-repair")
            value.financialId = "financial-rule-repair"
            value.importedPayee = "Coffee"
            return value
        }()
        let importedId = imported.id
        try database.insertTransaction(imported)

        let result = try await syncClient.createTransaction(imported, applyRules: true)
        #expect(result == .inserted(importedId))
        let persisted = try #require(await database.fetchTransaction(id: importedId))
        #expect(persisted.notes == "Rule note")

        let messageValues = try await database.dbQueueForTesting.read { db in
            try String.fetchAll(db, sql: """
                SELECT value FROM messages_crdt
                WHERE dataset = 'transactions' AND row = ? AND column = 'notes'
                """, arguments: [importedId])
        }
        #expect(messageValues == [CRDTValue.serialize(persisted.syncableFields["notes"] ?? nil)])
        let timestamps = try await database.dbQueueForTesting.read { db in
            try String.fetchAll(db, sql: "SELECT timestamp FROM messages_crdt")
        }
        var expected = MerkleTree()
        for timestamp in timestamps {
            expected = expected.inserting(try #require(HLCTimestamp.parse(timestamp)))
        }
        #expect(try database.deriveMerkleFromMessageLog().root.hash == expected.pruned().root.hash)
    }

    @Test func partialFinancialIdStateIsRejectedWithoutAppendingMessages() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)
        let imported: Transaction = {
            var value = transaction(id: "tx-partial")
            value.financialId = "financial-partial"
            return value
        }()
        try database.insertTransaction(imported)
        let partial = CRDTMessage(
            timestamp: HLCTimestamp(millis: 1_700_000_000_000, counter: 0, node: "89e0e8e90b203f9e"),
            dataset: "transactions", row: imported.id, column: "amount", value: "N:-1234")
        _ = try database.insertMessages([partial])

        await #expect(throws: BudgetDatabase.TransactionWriteError.incompleteFinancialIdMessages) {
            try await syncClient.createTransaction(imported, applyRules: true)
        }
        let messageCount = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE row = ?", arguments: [imported.id]) ?? 0
        }
        #expect(messageCount == 1)
        #expect(try database.deriveMerkleFromMessageLog().root.hash == MerkleTree().inserting(partial.timestamp).pruned().root.hash)
    }

    @Test func tombstonedFinancialIdCanBeReimportedWithANewRow() throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        try database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, financial_id, tombstone)
                VALUES ('tx-deleted', 'acct-1', 20260811, -1234, 'financial-reimport', 1)
                """)
        }

        var imported = transaction(id: "tx-reimported")
        imported.financialId = "financial-reimport"
        let message = CRDTMessage(
            timestamp: HLCTimestamp(millis: 1_700_000_000_000, counter: 0, node: "89e0e8e90b203f9e"),
            dataset: "transactions", row: imported.id, column: "financial_id", value: "S:financial-reimport"
        )

        #expect(try database.insertTransactionWithMessages(imported, messages: [message]).count == 1)
        let count = try database.dbQueueForTesting.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transactions WHERE financial_id = ?",
                arguments: [imported.financialId]
            )
        }
        #expect(count == 2)
    }

}
