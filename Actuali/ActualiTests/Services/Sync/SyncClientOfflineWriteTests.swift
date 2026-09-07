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

    @Test func concurrentFinancialIdCreatesCommitOneRowAndOneMessageSet() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        var first = transaction(id: "tx-concurrent-financial-1")
        first.financialId = "financial-concurrent"
        var second = transaction(id: "tx-concurrent-financial-2")
        second.financialId = first.financialId
        let candidates = [first, second]

        let outcomes = try await withThrowingTaskGroup(of: SyncClient.TransactionCreateResult.self) { group in
            for candidate in candidates {
                group.addTask {
                    try await syncClient.createTransaction(candidate, applyRules: false)
                }
            }

            var results: [SyncClient.TransactionCreateResult] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        #expect(outcomes.count == 2)
        #expect(outcomes.filter {
            if case .duplicate = $0 { return true }
            return false
        }.count == 1)
        let insertedIds = outcomes.compactMap { outcome in
            if case let .inserted(id) = outcome { return id }
            return nil
        }
        #expect(insertedIds.count == 1)
        let insertedId = try #require(insertedIds.first)
        let inserted = try #require(candidates.first { $0.id == insertedId })

        let durableRows = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transactions
                WHERE acct = ? AND financial_id = ?
                """, arguments: [inserted.accountId, inserted.financialId]) ?? 0
        }
        #expect(durableRows == 1)

        let messageRows = try database.dbQueueForTesting.read { db in
            try Row.fetchAll(db, sql: """
                SELECT row, column FROM messages_crdt
                WHERE dataset = 'transactions'
                """)
        }
        #expect(Set(messageRows.map { $0["row"] as String }) == Set([inserted.id]))
        #expect(Set(messageRows.map { $0["column"] as String }) == Set(inserted.syncableFields.keys))
        #expect(messageRows.count == inserted.syncableFields.count)
    }

    @Test func bankSyncFinancialIdOccurrenceLimitIsAtomicAndRepairsFirst() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)
        let prepared = SyncClient.PreparedRules(rules: [], context: .empty)

        let first: Transaction = {
            var value = transaction(id: "tx-bank-occurrence-1")
            value.financialId = "financial-bank-occurrence"
            return value
        }()
        let second: Transaction = {
            var value = transaction(id: "tx-bank-occurrence-2")
            value.financialId = "financial-bank-occurrence"
            return value
        }()
        let third: Transaction = {
            var value = transaction(id: "tx-bank-occurrence-3")
            value.financialId = "financial-bank-occurrence"
            return value
        }()

        #expect(try await syncClient.createBankSyncTransaction(
            first, maxLiveFinancialIdOccurrences: 2, prepared: prepared
        ) == .inserted(first.id))
        #expect(try await syncClient.createBankSyncTransaction(
            second, maxLiveFinancialIdOccurrences: 2, prepared: prepared
        ) == .inserted(second.id))
        #expect(try await syncClient.createBankSyncTransaction(
            third, maxLiveFinancialIdOccurrences: 2, prepared: prepared
        ) == .duplicate)

        #expect(try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transactions
                WHERE acct = ? AND financial_id = ? AND tombstone = 0
                """, arguments: [first.accountId, first.financialId]) ?? 0
        } == 2)

        let generic: Transaction = {
            var value = transaction(id: "tx-bank-occurrence-generic")
            value.financialId = "financial-bank-occurrence"
            return value
        }()
        #expect(try await syncClient.createTransaction(generic, applyRules: false) == .duplicate)

        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "DELETE FROM messages_crdt WHERE row = ?", arguments: [first.id])
        }
        #expect(try await syncClient.createBankSyncTransaction(
            first, maxLiveFinancialIdOccurrences: 1, prepared: prepared
        ) == .inserted(first.id))
        #expect(try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE row = ?", arguments: [first.id]) ?? 0
        } == first.syncableFields.count)
    }

    @Test(arguments: ["reconciled", "tombstone", "moved", "child", "date", "amount", "payee", "financial_id", "imported_description", "notes", "cleared"])
    func bankSyncUpdateSkipsRowsThatChangedAfterPlanning(_ state: String) async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        let existing = transaction(id: "tx-bank-race-\(state)")
        try database.insertTransaction(existing)
        let candidate = BankSyncCandidate(
            importedId: "financial-race-\(state)",
            date: existing.date,
            amount: existing.amount,
            payeeName: "Updated",
            payeeId: "payee-updated",
            notes: "Updated",
            cleared: true
        )
        let window = try await database.bankSyncWindow(
            accountId: existing.accountId,
            from: candidate.date - 7,
            to: candidate.date + 7,
            importedIds: [candidate.importedId]
        )
        let plan = BankSyncReconciler.plan(candidates: [candidate], existing: window)
        let update = try #require(plan.updates.first)

        switch state {
        case "reconciled":
            try await database.dbQueueForTesting.write { db in
                try db.execute(sql: "UPDATE transactions SET reconciled = 1 WHERE id = ?", arguments: [existing.id])
            }
        case "tombstone":
            try await database.dbQueueForTesting.write { db in
                try db.execute(sql: "UPDATE transactions SET tombstone = 1 WHERE id = ?", arguments: [existing.id])
            }
        case "moved":
            try await database.dbQueueForTesting.write { db in
                try db.execute(sql: "UPDATE transactions SET acct = ? WHERE id = ?", arguments: ["acct-other", existing.id])
            }
        case "child":
            try await database.dbQueueForTesting.write { db in
                try db.execute(sql: "UPDATE transactions SET isChild = 1 WHERE id = ?", arguments: [existing.id])
            }
        case "date", "amount", "payee", "financial_id", "imported_description", "notes", "cleared":
            switch state {
            case "date":
                try await database.dbQueueForTesting.write { db in
                    try db.execute(sql: "UPDATE transactions SET date = ? WHERE id = ?", arguments: [20260812, existing.id])
                }
            case "amount":
                try await database.dbQueueForTesting.write { db in
                    try db.execute(sql: "UPDATE transactions SET amount = ? WHERE id = ?", arguments: [-4321, existing.id])
                }
            case "payee":
                try await database.dbQueueForTesting.write { db in
                    try db.execute(sql: "UPDATE transactions SET description = ? WHERE id = ?", arguments: ["payee-concurrent", existing.id])
                }
            case "financial_id":
                try await database.dbQueueForTesting.write { db in
                    try db.execute(sql: "UPDATE transactions SET financial_id = ? WHERE id = ?", arguments: ["financial-concurrent", existing.id])
                }
            case "imported_description":
                try await database.dbQueueForTesting.write { db in
                    try db.execute(sql: "UPDATE transactions SET imported_description = ? WHERE id = ?", arguments: ["Imported concurrent", existing.id])
                }
            case "notes":
                try await database.dbQueueForTesting.write { db in
                    try db.execute(sql: "UPDATE transactions SET notes = ? WHERE id = ?", arguments: ["Concurrent notes", existing.id])
                }
            default:
                try await database.dbQueueForTesting.write { db in
                    try db.execute(sql: "UPDATE transactions SET cleared = ? WHERE id = ?", arguments: [1, existing.id])
                }
            }
        default:
            Issue.record("Unknown state: \(state)")
        }

        let applied = try await syncClient.applyBankSyncUpdates(
            [update], expectedAccountId: existing.accountId
        )

        #expect(applied == 0)
        #expect(try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'transactions' AND row = ?", arguments: [existing.id]) ?? 0
        } == 0)
        #expect(try await database.dbQueueForTesting.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT acct, date, amount, description, financial_id, imported_description, notes, cleared, reconciled, tombstone, isChild FROM transactions WHERE id = ?", arguments: [existing.id])
            switch state {
            case "reconciled": return row?["reconciled"] as Int? == 1
            case "tombstone": return row?["tombstone"] as Int? == 1
            case "moved": return row?["acct"] as String? == "acct-other"
            case "child": return row?["isChild"] as Int? == 1
            case "date": return row?["date"] as Int? == 20260812
            case "amount": return row?["amount"] as Int? == -4321
            case "payee": return row?["description"] as String? == "payee-concurrent"
            case "financial_id": return row?["financial_id"] as String? == "financial-concurrent"
            case "imported_description": return row?["imported_description"] as String? == "Imported concurrent"
            case "notes": return row?["notes"] as String? == "Concurrent notes"
            case "cleared": return row?["cleared"] as Int? == 1
            default: return false
            }
        })
    }

    @Test func bankSyncUpdateAppliesUnchangedPlanAndInsertsMessages() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        let existing = transaction(id: "tx-bank-cas-control")
        try database.insertTransaction(existing)
        let candidate = BankSyncCandidate(
            importedId: "financial-cas-control",
            date: existing.date,
            amount: existing.amount,
            payeeName: "Updated",
            payeeId: "payee-updated",
            notes: "Updated",
            cleared: true
        )
        let window = try await database.bankSyncWindow(
            accountId: existing.accountId,
            from: candidate.date - 7,
            to: candidate.date + 7,
            importedIds: [candidate.importedId]
        )
        let plan = BankSyncReconciler.plan(candidates: [candidate], existing: window)
        let applied = try await syncClient.applyBankSyncUpdates(
            plan.updates, expectedAccountId: existing.accountId
        )

        #expect(applied == 1)
        #expect(try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'transactions' AND row = ?", arguments: [existing.id]) ?? 0
        } == 5)
    }

    @Test func rejectedBankFinancialIdDoesNotLeavePendingPayeeRows() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)
        let prepared = SyncClient.PreparedRules(rules: [], context: .empty)

        var accepted = transaction(id: "tx-bank-payee-accepted")
        accepted.financialId = "financial-payee-limit"
        accepted.payeeId = "payee-existing"
        #expect(try await syncClient.createBankSyncTransaction(
            accepted, maxLiveFinancialIdOccurrences: 1, prepared: prepared
        ) == .inserted(accepted.id))

        var rejected = transaction(id: "tx-bank-payee-rejected")
        rejected.financialId = accepted.financialId
        rejected.payeeId = nil
        rejected.payeeName = "Never Seen Payee"
        #expect(try await syncClient.createBankSyncTransaction(
            rejected, maxLiveFinancialIdOccurrences: 1, prepared: prepared
        ) == .duplicate)

        let rejectedPayeeName = rejected.payeeName
        let acceptedId = accepted.id
        let counts = try await database.dbQueueForTesting.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM payees WHERE name = ?", arguments: [rejectedPayeeName]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM payee_mapping pm JOIN payees p ON p.id = pm.targetId WHERE p.name = ?", arguments: [rejectedPayeeName]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt m JOIN payees p ON p.id = m.row WHERE p.name = ?", arguments: [rejectedPayeeName]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions WHERE id = ?", arguments: [acceptedId]) ?? 0
            )
        }
        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
        #expect(counts.2 == 0)
        #expect(counts.3 == 1)
    }

    @Test func legacyNullAccountFinancialIdLookupIsNullSafeAndAccountScoped() throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        try database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, financial_id, tombstone)
                VALUES ('tx-legacy-null-account', NULL, 20260811, -1234, 'financial-null-account', 0)
                """)
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, financial_id, tombstone)
                VALUES ('tx-real-account', 'acct-1', 20260811, -1234, 'financial-null-account', 0)
                """)
        }

        let nullAccountMatch = try database.dbQueueForTesting.read { db in
            try String.fetchOne(db, sql: """
                SELECT id FROM transactions
                WHERE acct IS NULL AND financial_id = ?
                    AND (tombstone = 0 OR tombstone IS NULL)
                LIMIT 1
                """, arguments: ["financial-null-account"])
        }
        let realAccountMatch = try database.dbQueueForTesting.read { db in
            try String.fetchOne(db, sql: """
                SELECT id FROM transactions
                WHERE acct IS ? AND financial_id = ?
                    AND (tombstone = 0 OR tombstone IS NULL)
                LIMIT 1
                """, arguments: ["acct-1", "financial-null-account"])
        }

        #expect(nullAccountMatch == "tx-legacy-null-account")
        #expect(realAccountMatch == "tx-real-account")
    }

    @Test func zeroMessageFinancialIdRetryRepairsThroughSyncClient() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let imported: Transaction = {
            var value = transaction(id: "tx-zero-message")
            value.financialId = "financial-zero-message"
            value.importedPayee = "Imported Coffee"
            value.schedule = "schedule-zero-message"
            value.startingBalanceFlag = true
            return value
        }()
        try database.insertTransaction(imported)
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                UPDATE transactions
                SET isChild = 1,
                    sort_order = 123.0,
                    imported_description = 'stale imported description',
                    schedule = 'stale schedule',
                    starting_balance_flag = 0
                WHERE id = ?
                """, arguments: [imported.id])
        }

        let syncClient = try await makeSyncClient(database: database)

        let result = try await syncClient.createTransaction(imported, applyRules: true)
        #expect(result == .inserted("tx-zero-message"))
        let storedValues = try await database.dbQueueForTesting.read { db in
            let messages = try Row.fetchAll(db, sql: """
                SELECT column, value FROM messages_crdt
                WHERE dataset = 'transactions' AND row = ?
                """, arguments: [imported.id])
            var values: [String: DatabaseValue] = [:]
            for message in messages {
                values[message["column"]] = CRDTValue.deserialize(message["value"])
            }
            return values
        }
        #expect(storedValues.count == imported.syncableFields.count)
        let fetchedRow = try database.dbQueueForTesting.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM transactions WHERE id = ?", arguments: [imported.id])
        }
        let repairedRow = try #require(fetchedRow)
        for column in ["isChild", "sort_order", "imported_description", "schedule", "financial_id", "starting_balance_flag"] {
            #expect(repairedRow[column] == storedValues[column], "Mismatch for \(column)")
        }
        #expect(repairedRow["sort_order"] == storedValues["sort_order"])
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
