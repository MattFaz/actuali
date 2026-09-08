import Foundation
import GRDB
import Testing
@testable import Actuali

/// A server that accepts the connection and then never answers in time — what
/// an unreachable self-hosted server looks like to URLSession (the request
/// hangs until the timeout rather than failing fast).
private final class StallingSyncTransport: URLProtocol {
    /// number of seconds. A wall-clock bound can't tell "the caller awaited
    /// the push" from "the runner was starved": CI measured 4s across a window
    /// that takes 20ms locally and failed a 3s bound with nothing wrong. Held
    /// open, a caller that awaits the push simply never returns, which the
    /// test's time limit catches no matter how slow the machine is.
    private static let gate = NSCondition()
    nonisolated(unsafe) private static var isOpen = false
    nonisolated(unsafe) private static var attempts = 0
    nonisolated(unsafe) private static var completions = 0

    /// Safety net so a request left in flight by an earlier test can't hold a
    /// URLSession thread for the life of the suite.
    private static let maxStall: TimeInterval = 60

    static func reset() {
        gate.lock()
        isOpen = false
        attempts = 0
        completions = 0
        gate.unlock()
    }

    /// Let every stalled request fail so its thread unwinds.
    static func release() {
        gate.lock()
        isOpen = true
        gate.broadcast()
        gate.unlock()
    }

    static var attemptCount: Int {
        gate.lock()
        defer { gate.unlock() }
        return attempts
    }

    /// Requests that have finished stalling — zero for as long as the gate is
    /// shut, so a caller that returned while this is zero cannot have waited
    /// for the server to answer.
    static var completionCount: Int {
        gate.lock()
        defer { gate.unlock() }
        return completions
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.gate.lock()
        Self.attempts += 1
        let deadline = Date(timeIntervalSinceNow: Self.maxStall)
        // wait(until:) returns false once the deadline passes.
        while !Self.isOpen, Self.gate.wait(until: deadline) {}
        Self.completions += 1
        Self.gate.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}

private final class ImmediateFailureSyncTransport: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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

    private static let expectedBankSyncLink = ExpectedBankSyncLink(
        accountId: "acct-1", externalAccountId: "external-acct-1", source: "simpleFin"
    )

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
                    tombstone INTEGER DEFAULT 0,
                    account_id TEXT,
                    account_sync_source TEXT
                )
                """)
            try db.execute(sql: """
                INSERT INTO accounts (id, account_id, account_sync_source)
                VALUES ('acct-1', 'external-acct-1', 'simpleFin')
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
    private func makeSyncClient(
        database: BudgetDatabase,
        stallRequests: Bool = false
    ) async throws -> SyncClient {
        let config = URLSessionConfiguration.ephemeral
        if stallRequests {
            StallingSyncTransport.reset()
            config.protocolClasses = [StallingSyncTransport.self]
        } else {
            config.protocolClasses = [ImmediateFailureSyncTransport.self]
        }
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

    private func cancelStalledSync(_ syncClient: SyncClient) async {
        StallingSyncTransport.release()
        await syncClient.cancelPendingSync()
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
    /// The time limit is half the assertion — the gate stays shut for the
    /// duration of the test, so a caller that awaits the push never returns at
    /// all rather than returning slowly.
    @Test(.timeLimit(.minutes(1)))
    func createTransactionReturnsWithoutWaitingForTheServer() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database, stallRequests: true)
        defer { StallingSyncTransport.release() }

        do {
            try await syncClient.createTransaction(transaction(id: "tx-offline-1"))

            // Returned while the server is still hanging: nothing has been allowed
            // to answer yet, so the push cannot have been awaited.
            #expect(StallingSyncTransport.completionCount == 0, "createTransaction waited for the unreachable server to answer")
            // Local-first: the transaction is already durable on return.
            #expect(try rowExists(database, id: "tx-offline-1"))
        } catch {
            await cancelStalledSync(syncClient)
            throw error
        }

        await cancelStalledSync(syncClient)
    }

    /// Deferred, not dropped: the push still goes out, just off the caller's
    /// thread.
    @Test func pushStillHappensAfterTheWriteReturns() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database, stallRequests: true)
        defer { StallingSyncTransport.release() }

        do {
            try await syncClient.createTransaction(transaction(id: "tx-offline-2"))

            var observed = StallingSyncTransport.attemptCount
            for _ in 0..<40 where observed == 0 {
                try await Task.sleep(nanoseconds: 50_000_000)
                observed = StallingSyncTransport.attemptCount
            }
            #expect(observed >= 1, "the deferred sync never reached the server")
        } catch {
            await cancelStalledSync(syncClient)
            throw error
        }

        await cancelStalledSync(syncClient)
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
        let prepared = try await syncClient.prepareRules()

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
            first, maxLiveFinancialIdOccurrences: 2, prepared: prepared,
            expectedLink: Self.expectedBankSyncLink
        ) == .inserted(first.id))
        #expect(try await syncClient.createBankSyncTransaction(
            second, maxLiveFinancialIdOccurrences: 2, prepared: prepared,
            expectedLink: Self.expectedBankSyncLink
        ) == .inserted(second.id))
        #expect(try await syncClient.createBankSyncTransaction(
            third, maxLiveFinancialIdOccurrences: 2, prepared: prepared,
            expectedLink: Self.expectedBankSyncLink
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
            first, maxLiveFinancialIdOccurrences: 1, prepared: prepared,
            expectedLink: Self.expectedBankSyncLink
        ) == .inserted(first.id))
        #expect(try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE row = ?", arguments: [first.id]) ?? 0
        } == first.syncableFields.count)
    }

    @Test(arguments: ["reconciled", "tombstone", "starting_balance", "child", "date", "amount", "payee", "financial_id", "imported_description", "notes", "cleared"])
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
        case "starting_balance":
            try await database.dbQueueForTesting.write { db in
                try db.execute(sql: "UPDATE transactions SET starting_balance_flag = 1 WHERE id = ?", arguments: [existing.id])
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
            [update], expectedLink: Self.expectedBankSyncLink
        )

        #expect(applied == 0)
        #expect(try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'transactions' AND row = ?", arguments: [existing.id]) ?? 0
        } == 0)
        #expect(try await database.dbQueueForTesting.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT acct, date, amount, description, financial_id, imported_description, notes, cleared, reconciled, tombstone, starting_balance_flag, isChild FROM transactions WHERE id = ?", arguments: [existing.id])
            switch state {
            case "reconciled": return row?["reconciled"] as Int? == 1
            case "tombstone": return row?["tombstone"] as Int? == 1
            case "starting_balance": return row?["starting_balance_flag"] as Int? == 1
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

    @Test func bankSyncWindowExcludesStartingBalanceRowsFromFuzzyMatching() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        var openingBalance = transaction(id: "tx-bank-opening-balance")
        openingBalance.startingBalanceFlag = true
        try database.insertTransaction(openingBalance)

        let candidate = BankSyncCandidate(
            importedId: "financial-opening-balance",
            date: openingBalance.date,
            amount: openingBalance.amount,
            payeeName: "Updated",
            payeeId: "payee-updated",
            notes: "Updated",
            cleared: true
        )
        let window = try await database.bankSyncWindow(
            accountId: openingBalance.accountId,
            from: candidate.date - 7,
            to: candidate.date + 7,
            importedIds: [candidate.importedId]
        )
        let plan = BankSyncReconciler.plan(candidates: [candidate], existing: window)

        #expect(window.isEmpty)
        #expect(plan.updates.isEmpty)
        #expect(plan.inserts.map(\.importedId) == [candidate.importedId])
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
            plan.updates, expectedLink: Self.expectedBankSyncLink
        )

        #expect(applied == 1)
        #expect(try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'transactions' AND row = ?", arguments: [existing.id]) ?? 0
        } == 5)
    }

    @Test func standaloneBankAPIsRejectAStaleLinkWithoutWriting() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)
        let staleLink = ExpectedBankSyncLink(
            accountId: "acct-1", externalAccountId: "stale-external-id", source: "simpleFin"
        )
        let prepared = try await syncClient.prepareRules()
        var imported = transaction(id: "tx-stale-bank-api")
        imported.financialId = "financial-stale-bank-api"
        let importedId = imported.id

        await #expect(throws: BankSyncDatabaseError.bankSyncMaterializationStale) {
            _ = try await syncClient.createBankSyncTransaction(
                imported, maxLiveFinancialIdOccurrences: 1, prepared: prepared,
                expectedLink: staleLink
            )
        }

        let existing = transaction(id: "tx-stale-bank-update")
        try database.insertTransaction(existing)
        let update = BankSyncUpdate(
            expected: .init(
                id: existing.id,
                date: existing.date,
                amount: existing.amount,
                payeeId: existing.payeeId,
                importedId: existing.financialId,
                importedPayee: existing.importedPayee,
                notes: existing.notes,
                cleared: existing.cleared,
                reconciled: existing.reconciled,
                tombstone: existing.tombstone
            ),
            existingId: existing.id,
            importedId: "financial-stale-update",
            payeeId: "payee-updated",
            importedPayee: "Updated",
            notes: nil,
            cleared: true
        )
        await #expect(throws: BankSyncDatabaseError.bankSyncMaterializationStale) {
            _ = try await syncClient.applyBankSyncUpdates([update], expectedLink: staleLink)
        }

        let counts = try await database.dbQueueForTesting.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions WHERE id = ?", arguments: [importedId]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0
            )
        }
        #expect(counts == (0, 0))
    }

    @Test func staleBankStatusDoesNotDiscardOrReplicateValidStatuses() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO accounts (id, account_id, account_sync_source)
                VALUES ('acct-2', 'external-acct-2-new', 'simpleFin')
                """)
        }

        try await syncClient.recordBankSyncStatus([
            (
                accountId: "acct-1",
                lastSync: "1700000000000",
                status: "ok",
                expectedLink: Self.expectedBankSyncLink
            ),
            (
                accountId: "acct-2",
                lastSync: "1700000000000",
                status: "failed",
                expectedLink: ExpectedBankSyncLink(
                    accountId: "acct-2",
                    externalAccountId: "external-acct-2-old",
                    source: "simpleFin"
                )
            )
        ])

        let state = try await database.dbQueueForTesting.read { db in
            (
                validStatus: try String.fetchOne(
                    db, sql: "SELECT bank_sync_status FROM accounts WHERE id = 'acct-1'"
                ),
                staleStatus: try String.fetchOne(
                    db, sql: "SELECT bank_sync_status FROM accounts WHERE id = 'acct-2'"
                ),
                validMessages: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'accounts' AND row = 'acct-1'"
                ) ?? 0,
                staleMessages: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'accounts' AND row = 'acct-2'"
                ) ?? 0
            )
        }
        #expect(state.validStatus == "ok")
        #expect(state.staleStatus == nil)
        #expect(state.validMessages == 2)
        #expect(state.staleMessages == 0)
    }

    @Test func staleDuplicateBankStatusDoesNotReplicateItsMessages() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.recordBankSyncStatus([
            (
                accountId: "acct-1",
                lastSync: nil,
                status: "failed",
                expectedLink: ExpectedBankSyncLink(
                    accountId: "acct-1",
                    externalAccountId: "external-acct-1-old",
                    source: "simpleFin"
                )
            ),
            (
                accountId: "acct-1",
                lastSync: "1700000000000",
                status: "ok",
                expectedLink: Self.expectedBankSyncLink
            )
        ])

        let state = try await database.dbQueueForTesting.read { db in
            (
                status: try String.fetchOne(
                    db, sql: "SELECT bank_sync_status FROM accounts WHERE id = 'acct-1'"
                ),
                lastSync: try String.fetchOne(
                    db, sql: "SELECT last_sync FROM accounts WHERE id = 'acct-1'"
                ),
                messageCount: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'accounts' AND row = 'acct-1'"
                ) ?? 0
            )
        }
        #expect(state.status == "ok")
        #expect(state.lastSync == "1700000000000")
        #expect(state.messageCount == 2)
    }

    @Test func bankStatusCannotValidateOneAccountAndUpdateAnother() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "INSERT INTO accounts (id) VALUES ('acct-2')")
        }

        try await syncClient.recordBankSyncStatus([(
            accountId: "acct-2",
            lastSync: "1700000000000",
            status: "ok",
            expectedLink: Self.expectedBankSyncLink
        )])

        let state = try await database.dbQueueForTesting.read { db in
            (
                status: try String.fetchOne(
                    db, sql: "SELECT bank_sync_status FROM accounts WHERE id = 'acct-2'"
                ),
                messageCount: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'accounts' AND row = 'acct-2'"
                ) ?? 0
            )
        }
        #expect(state.status == nil)
        #expect(state.messageCount == 0)
    }

    @Test func bankSyncMaterializationRejectsStalePreparedRulesBeforeWriting() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "INSERT INTO rules (id, stage, conditions_op, conditions, actions) VALUES ('rule-1', NULL, 'and', '[]', '[{\"op\":\"set\",\"field\":\"category\",\"value\":\"cat-1\"}]')")
        }
        let syncClient = try await makeSyncClient(database: database)
        let prepared = try await syncClient.prepareRules()
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "UPDATE rules SET actions = ? WHERE id = 'rule-1'", arguments: ["[{\"op\":\"set\",\"field\":\"category\",\"value\":\"cat-2\"}]"])
        }

        var imported = transaction(id: "tx-stale-rules")
        imported.financialId = "financial-stale-rules"
        let message = CRDTMessage(
            timestamp: HLCTimestamp(millis: 1_700_000_000_000, counter: 0, node: "89e0e8e90b203f9e"),
            dataset: "transactions", row: imported.id, column: "amount", value: "N:-1234"
        )
        await #expect(throws: BankSyncDatabaseError.bankSyncRulesChanged) {
            _ = try await syncClient.materializeBankSync(
                updates: [],
                inserts: [PreparedBankSyncInsert(
                    transaction: imported,
                    messages: [message],
                    pendingPayees: [Payee(id: "payee-new", name: "New Payee", transferAccountId: nil)],
                    maxLiveFinancialIdOccurrences: 1
                )],
                openingInsert: nil,
                openingUpdate: nil,
                expectedLink: ExpectedBankSyncLink(
                    accountId: "acct-1", externalAccountId: "external-acct-1", source: "simpleFin"
                ),
                preparedRulesFingerprint: prepared.fingerprint
            )
        }

        let counts = try await database.dbQueueForTesting.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM payees") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0
            )
        }
        #expect(counts == (0, 0, 0))
    }

    @Test func bankSyncMaterializationToleratesPartialRulesContextSchema() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "ALTER TABLE accounts DROP COLUMN offbudget")
            try db.execute(sql: "INSERT INTO rules (id, stage, conditions_op, conditions, actions) VALUES ('rule-1', NULL, 'and', '[]', '[{\"op\":\"set\",\"field\":\"category\",\"value\":\"cat-1\"}]')")
        }
        let syncClient = try await makeSyncClient(database: database)
        let prepared = try await syncClient.prepareRules()

        var imported = transaction(id: "tx-partial-rules-context")
        imported.financialId = "financial-partial-rules-context"
        let message = CRDTMessage(
            timestamp: HLCTimestamp(millis: 1_700_000_000_000, counter: 0, node: "89e0e8e90b203f9e"),
            dataset: "transactions", row: imported.id, column: "amount", value: "N:-1234"
        )
        let result = try await syncClient.materializeBankSync(
            updates: [],
            inserts: [PreparedBankSyncInsert(
                transaction: imported,
                messages: [message],
                pendingPayees: [],
                maxLiveFinancialIdOccurrences: 1
            )],
            openingInsert: nil,
            openingUpdate: nil,
            expectedLink: Self.expectedBankSyncLink,
            preparedRulesFingerprint: prepared.fingerprint
        )

        #expect(result.inserted.map(\.id) == [imported.id])
    }

    @Test func rejectedBankFinancialIdDoesNotLeavePendingPayeeRows() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)
        let prepared = try await syncClient.prepareRules()

        var accepted = transaction(id: "tx-bank-payee-accepted")
        accepted.financialId = "financial-payee-limit"
        accepted.payeeId = "payee-existing"
        #expect(try await syncClient.createBankSyncTransaction(
            accepted, maxLiveFinancialIdOccurrences: 1, prepared: prepared,
            expectedLink: Self.expectedBankSyncLink
        ) == .inserted(accepted.id))

        var rejected = transaction(id: "tx-bank-payee-rejected")
        rejected.financialId = accepted.financialId
        rejected.payeeId = nil
        rejected.payeeName = "Never Seen Payee"
        #expect(try await syncClient.createBankSyncTransaction(
            rejected, maxLiveFinancialIdOccurrences: 1, prepared: prepared,
            expectedLink: Self.expectedBankSyncLink
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

    @Test func bankSyncMaterializationRollsBackConflictingPendingPayeePayload() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        try await database.dbQueueForTesting.write { db in
        }
        let syncClient = try await makeSyncClient(database: database)
        let preparedRules = try await syncClient.prepareRules()
        var first = transaction(id: "tx-pending-payee-conflict-1")
        first.financialId = "financial-pending-payee-conflict-1"
        first.payeeId = nil
        first.payeeName = "Original Merchant"
        let prepared = try #require(await syncClient.prepareBankSyncTransaction(
            first, prepared: preparedRules
        ))
        let firstPayee = try #require(prepared.pendingPayees.first)
        var second = transaction(id: "tx-pending-payee-conflict-2")
        second.financialId = "financial-pending-payee-conflict-2"
        second.payeeId = nil
        second.payeeName = "Different Merchant"
        let conflictingPayee = Payee(
            id: firstPayee.id,
            name: "Different Merchant",
            transferAccountId: firstPayee.transferAccountId,
            tombstone: firstPayee.tombstone
        )

        await #expect(throws: BankSyncDatabaseError.bankSyncPendingPayeeConflict) {
            _ = try await syncClient.materializeBankSync(
                updates: [],
                inserts: [
                    PreparedBankSyncInsert(
                        transaction: prepared.transaction,
                        messages: prepared.messages,
                        pendingPayees: prepared.pendingPayees,
                        maxLiveFinancialIdOccurrences: 1
                    ),
                    PreparedBankSyncInsert(
                        transaction: second,
                        messages: [],
                        pendingPayees: [conflictingPayee],
                        maxLiveFinancialIdOccurrences: 1
                    )
                ],
                openingInsert: nil,
                openingUpdate: nil,
                expectedLink: ExpectedBankSyncLink(
                    accountId: "acct-1",
                    externalAccountId: "external-acct-1",
                    source: "simpleFin"
                ),
                preparedRulesFingerprint: preparedRules.fingerprint
            )
        }

        let counts = try await database.dbQueueForTesting.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM payees") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM payee_mapping") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0
            )
        }
        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
        #expect(counts.2 == 0)
        #expect(counts.3 == 0)
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
