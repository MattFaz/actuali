import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actuali

/// Answers /sync/sync the way a real server does: it folds the messages it
/// receives into its own tree before answering, so answering with a merkle
/// over those is what lets the client see itself as in sync — a stub that
/// always claimed an empty tree would leave every sync out of sync.
private final class SyncServer: Sendable {
    private let absorbed = Mutex<Set<String>>([])

    func respond(to request: URLRequest) -> StubTransport.Response {
        if let decoded = try? SyncRequest(serializedData: request.bodyData) {
            absorbed.withLock { $0.formUnion(decoded.messages.map(\.timestamp)) }
        }
        var response = SyncResponse()
        response.merkle = merkleJSON()
        return StubTransport.Response(
            contentType: "application/actual-sync",
            body: (try? response.serializedData()) ?? Data()
        )
    }

    private func merkleJSON() -> String {
        var tree = MerkleTree()
        for timestamp in absorbed.withLock({ $0.sorted() }) {
            guard let parsed = HLCTimestamp.parse(timestamp) else { continue }
            tree = tree.inserting(parsed)
        }
        guard let data = try? JSONEncoder().encode(tree.pruned().root),
              let json = String(data: data, encoding: .utf8)
        else { return #"{"hash":0}"# }
        return json
    }
}

/// Issue #139: the Shortcut used to report a plain success even when the row
/// never left the phone. `logTransaction` now reports whether the push landed
/// so `LogTransactionIntent` can say "Saved locally" instead.
@MainActor
struct TransactionLoggerSyncOutcomeTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.core + [TestSchema.rules, """
        INSERT INTO category_groups (id, name) VALUES ('grp-1', 'Daily');
        INSERT INTO categories (id, name, cat_group) VALUES
            ('cat-coffee', 'Coffee', 'grp-1'), ('cat-treats', 'Treats', 'grp-1');
        """])
    }

    /// A store whose sync client talks to `SyncServer`, or to nothing at all.
    private func makeStore(database: BudgetDatabase, serverReachable: Bool) async throws -> BudgetStore {
        let server = SyncServer()
        let session = StubTransport.session { request in
            guard serverReachable else { throw URLError(.notConnectedToInternet) }
            return server.respond(to: request)
        }
        let serverClient = ActualServerClient(session: session)
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("test-token")

        let syncClient = SyncClient(serverClient: serverClient, nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")

        let store = BudgetStore.previewInstance()
        store.configureForTesting(database: database, syncClient: syncClient)
        return store
    }

    private func log(to store: BudgetStore, categoryId: String? = nil) async throws -> TransactionLogger.Result {
        try await TransactionLogger(store: store).logTransaction(
            accountId: "acct-1",
            amountCents: -820,
            rawMerchant: "BLUE BOTTLE COFFEE",
            notes: nil,
            date: Date(timeIntervalSince1970: 1_750_000_000),
            categoryId: categoryId
        )
    }

    @Test func reachableServerReportsTheWriteAsSynced() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, serverReachable: true)

        let result = try await log(to: store)

        #expect(result.synced)
    }

    @Test func unrelatedPendingMessagesDoNotChangeThisTransactionOutcome() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, serverReachable: true)

        let result = try await log(to: store)
        let unrelated = CRDTMessage(
            timestamp: HLCTimestamp(millis: 1_900_000_000_000, counter: 0, node: "89e0e8e90b203f9e"),
            dataset: "transactions", row: "unrelated-row", column: "amount", value: "N:-1"
        )
        _ = try database.insertMessages([unrelated])

        #expect(await store.hasPendingLocalWrites())
        #expect(await !(store.hasPendingLocalWrites(
            dataset: Transaction.datasetName,
            row: result.transaction.id
        )))
    }

    @Test func partialDeterministicImportIsRecoverableWithoutAppendingMessages() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, serverReachable: true)
        let transactionId = UUID().uuidString
        let financialId = "actuali-pending-import:partial"
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
            INSERT INTO transactions (id, acct, date, amount, financial_id, tombstone)
            VALUES (?, 'acct-1', 20260811, -820, ?, 0)
            """, arguments: [transactionId, financialId])
        }
        let partial = CRDTMessage(
            timestamp: HLCTimestamp(millis: 1_700_000_000_000, counter: 0, node: "89e0e8e90b203f9e"),
            dataset: "transactions", row: transactionId, column: "amount", value: "N:-820"
        )
        _ = try database.insertMessages([partial])

        await #expect(throws: TransactionLogger.LoggerError.transactionNeedsRecovery) {
            try await TransactionLogger(store: store).logTransaction(
                accountId: "acct-1",
                amountCents: -820,
                rawMerchant: "BLUE BOTTLE COFFEE",
                notes: nil,
                date: Date(timeIntervalSince1970: 1_750_000_000),
                financialId: financialId,
                transactionId: transactionId
            )
        }
        let messageCount = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages_crdt WHERE row = ?",
                arguments: [transactionId]
            ) ?? 0
        }
        #expect(messageCount == 1)
    }

    @Test func resultContainsTheRuleModifiedPersistedTransaction() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, serverReachable: true)
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
            INSERT INTO rules (id, stage, conditions_op, conditions, actions, tombstone)
            VALUES ('set-category', NULL, 'and',
                '[{"op":"contains","field":"imported_description","value":"BLUE"}]',
                '[{"op":"set","field":"category","value":"cat-rule","type":"id"}]', 0)
            """)
        }

        let result = try await log(to: store)

        #expect(result.transaction.categoryId == "cat-rule")
        let persistedCategory: String? = try await database.dbQueueForTesting.read { db in
            try String.fetchOne(db, sql: "SELECT category FROM transactions WHERE id = ?", arguments: [result.transaction.id])
        }
        #expect(persistedCategory == "cat-rule")
    }

    /// #283: a category pinned on the Shortcut is the user's choice, so it
    /// beats a category-setting rule, same as picking one in the add form.
    @Test func explicitCategoryWinsOverRules() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, serverReachable: true)
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
            INSERT INTO rules (id, stage, conditions_op, conditions, actions, tombstone)
            VALUES ('set-category', NULL, 'and',
                '[{"op":"contains","field":"imported_description","value":"BLUE"}]',
                '[{"op":"set","field":"category","value":"cat-rule","type":"id"}]', 0)
            """)
        }

        let result = try await log(to: store, categoryId: "cat-treats")

        #expect(result.transaction.categoryId == "cat-treats")
    }

    @Test func explicitCategoryWinsOverPayeeHistoryAndNilKeepsTheAutoPick() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, serverReachable: true)

        _ = try await log(to: store, categoryId: "cat-coffee")
        let pinned = try await log(to: store, categoryId: "cat-treats")
        let unpinned = try await log(to: store)

        #expect(pinned.transaction.categoryId == "cat-treats")
        #expect(unpinned.transaction.categoryId == "cat-treats")
    }

    /// A category deleted since the Shortcut was built must not be written as
    /// a dangling id; the payee auto-pick takes over instead.
    @Test func unknownCategoryFallsBackToTheAutoPick() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, serverReachable: true)

        _ = try await log(to: store, categoryId: "cat-coffee")
        let result = try await log(to: store, categoryId: "cat-deleted")

        #expect(result.transaction.categoryId == "cat-coffee")
    }

    /// Unreachable server: the row is still written (nothing is lost), but the
    /// caller is told it hasn't landed so the banner can say so.
    @Test func unreachableServerReportsTheWriteAsUnsynced() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, serverReachable: false)

        let result = try await log(to: store)

        #expect(!result.synced)

        let queue = try DatabaseQueue(path: url.path)
        let ids = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM transactions WHERE tombstone = 0")
        }
        #expect(ids.count == 1)
        #expect(ids.first == result.transaction.id)
    }
}
