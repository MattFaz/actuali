import Foundation
import GRDB
import Synchronization
import Testing
import UserNotifications
@testable import Actuali

/// `perform` posts its result notification. The real center would prompt for
/// permission on a fresh CI simulator and hang the run.
private struct DeniedNotificationCenter: NotificationPosting {
    func authorizationStatus() async -> UNAuthorizationStatus {
        .denied
    }

    func requestAuthorization(options _: UNAuthorizationOptions) async throws -> Bool {
        false
    }

    func add(_: UNNotificationRequest) async throws {}
    func removePendingNotificationRequests(withIdentifiers _: [String]) {}
}

/// Answers /sync/sync the way a real server does: it folds the messages it
/// receives into its own tree before answering, so answering with a merkle
/// over those is what lets the client see itself as in sync — a stub that
/// always claimed an empty tree would leave every sync out of sync.
private actor AsyncGate {
    private var entered = false
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

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
@Suite(.serialized)
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

    private func withStore(
        database: BudgetDatabase,
        serverReachable: Bool,
        operation: @MainActor (BudgetStore) async throws -> Void
    ) async throws {
        let store = try await makeStore(database: database, serverReachable: serverReachable)
        do {
            try await operation(store)
        } catch {
            await store.closeBudgetConnectionsForTesting()
            throw error
        }
        await store.closeBudgetConnectionsForTesting()
    }

    @Test func reachableServerReportsTheWriteAsSynced() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await withStore(database: database, serverReachable: true) { store in
            let result = try await log(to: store)
            #expect(result.synced)
        }
    }

    @Test func unrelatedPendingMessagesDoNotChangeThisTransactionOutcome() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await withStore(database: database, serverReachable: true) { store in
            let result = try await log(to: store)
            let unrelated = CRDTMessage(
                timestamp: HLCTimestamp(
                    millis: 1_900_000_000_000, counter: 0, node: "89e0e8e90b203f9e"
                ),
                dataset: "transactions", row: "unrelated-row", column: "amount", value: "N:-1"
            )
            _ = try database.insertMessages([unrelated])

            #expect(await store.hasPendingLocalWrites())
            #expect(await !(store.hasPendingLocalWrites(
                dataset: Transaction.datasetName,
                row: result.transaction.id
            )))
        }
    }

    @Test func partialDeterministicImportIsRecoverableWithoutAppendingMessages() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await withStore(database: database, serverReachable: true) { store in
            let transactionId = UUID().uuidString
            let financialId = "actuali-pending-import:partial"
            try await database.dbQueueForTesting.write { db in
                try db.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, financial_id, tombstone)
                VALUES (?, 'acct-1', 20260811, -820, ?, 0)
                """, arguments: [transactionId, financialId])
            }
            let partial = CRDTMessage(
                timestamp: HLCTimestamp(
                    millis: 1_700_000_000_000, counter: 0, node: "89e0e8e90b203f9e"
                ),
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
    }

    @Test func resultContainsTheRuleModifiedPersistedTransaction() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await withStore(database: database, serverReachable: true) { store in
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
                try String.fetchOne(
                    db,
                    sql: "SELECT category FROM transactions WHERE id = ?",
                    arguments: [result.transaction.id]
                )
            }
            #expect(persistedCategory == "cat-rule")
        }
    }

    /// #777: a rule that re-points the payee must not leave the normalized
    /// merchant behind as an unused payee. Upstream only creates an imported
    /// payee "if it ended up being used" (loot-core accounts/sync.ts).
    @Test func payeeReplacedByRuleIsNeverCreated() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await withStore(database: database, serverReachable: true) { store in
            try await database.dbQueueForTesting.write { db in
                try db.execute(sql: """
                INSERT INTO payees (id, name, tombstone) VALUES ('payee-mcd', 'McDonald''s', 0);
                INSERT INTO rules (id, stage, conditions_op, conditions, actions, tombstone)
                VALUES ('set-payee', NULL, 'and',
                    '[{"op":"contains","field":"imported_description","value":"MCDONALDS RIVERDALE"}]',
                    '[{"op":"set","field":"payee","value":"payee-mcd","type":"id"}]', 0)
                """)
            }

            let result = try await TransactionLogger(store: store).logTransaction(
                accountId: "acct-1",
                amountCents: -1250,
                rawMerchant: "MCDONALDS RIVERDALE 1234",
                notes: nil,
                date: Date(timeIntervalSince1970: 1_750_000_000)
            )

            #expect(result.transaction.payeeId == "payee-mcd")
            let payeeNames = try await database.dbQueueForTesting.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM payees")
            }
            #expect(payeeNames == ["McDonald's"])
            let payeeMessages = try await database.dbQueueForTesting.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'payees'"
                ) ?? 0
            }
            #expect(payeeMessages == 0)
        }
    }

    /// Deferring creation past the rules pass must still create and use the
    /// payee when no rule replaces it.
    @Test func newMerchantStillCreatesItsPayee() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await withStore(database: database, serverReachable: true) { store in
            let result = try await log(to: store)
            let payee = try database.payee(named: "Blue Bottle Coffee")
            #expect(payee != nil)
            #expect(result.transaction.payeeId == payee?.id)
        }
    }

    /// Rules see a provisional id for a new merchant, as upstream does, so a
    /// negated payee condition still matches it.
    @Test func newMerchantMatchesNegatedPayeeRule() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await withStore(database: database, serverReachable: true) { store in
            try await database.dbQueueForTesting.write { db in
                try db.execute(sql: """
                INSERT INTO rules (id, stage, conditions_op, conditions, actions, tombstone)
                VALUES ('not-rent', NULL, 'and',
                    '[{"op":"notOneOf","field":"description","value":["payee-rent"],"type":"id"}]',
                    '[{"op":"set","field":"category","value":"cat-treats","type":"id"}]', 0)
                """)
            }

            let result = try await log(to: store)
            #expect(result.transaction.categoryId == "cat-treats")
            #expect(try database.payee(named: "Blue Bottle Coffee")?.id == result.transaction.payeeId)
        }
    }

    /// #283: a category pinned on the Shortcut is the user's choice, so it
    /// beats a category-setting rule, same as picking one in the add form.
    @Test func explicitCategoryWinsOverRules() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await withStore(database: database, serverReachable: true) { store in
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
    }

    @Test func explicitCategoryWinsOverPayeeHistoryAndNilKeepsTheAutoPick() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await withStore(database: database, serverReachable: true) { store in
            _ = try await log(to: store, categoryId: "cat-coffee")
            let pinned = try await log(to: store, categoryId: "cat-treats")
            let unpinned = try await log(to: store)

            #expect(pinned.transaction.categoryId == "cat-treats")
            #expect(unpinned.transaction.categoryId == "cat-treats")
        }
    }

    /// With the payee-history pick off, an unpinned log stays uncategorized
    /// instead of copying the payee's last category.
    @Test func payeeHistoryOffLeavesAnUnpinnedLogUncategorized() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await withStore(database: database, serverReachable: true) { store in
            let key = "suggestCategoryFromPayeeHistory"
            let original = UserDefaults.standard.object(forKey: key)
            defer { restoreUserDefault(key, to: original) }

            _ = try await log(to: store, categoryId: "cat-coffee")
            store.suggestCategoryFromPayeeHistory = false
            let unpinned = try await log(to: store)
            #expect(unpinned.transaction.categoryId == nil)
        }
    }

    /// A category deleted since the Shortcut was built must not be written as
    /// a dangling id; the payee auto-pick takes over instead.
    @Test func unknownCategoryFallsBackToTheAutoPick() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await withStore(database: database, serverReachable: true) { store in
            _ = try await log(to: store, categoryId: "cat-coffee")
            let result = try await log(to: store, categoryId: "cat-deleted")
            #expect(result.transaction.categoryId == "cat-coffee")
        }
    }

    /// Unreachable server: the row is still written (nothing is lost), but the
    /// caller is told it hasn't landed so the banner can say so.
    @Test func unreachableServerReportsTheWriteAsUnsynced() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await withStore(database: database, serverReachable: false) { store in
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

    private func makeTargetBudgetSchema(accountId: String = "acct-1") -> String {
        let seedRows = [
            """
            INSERT INTO accounts (
                id, name, offbudget, closed, tombstone, sort_order
            ) VALUES ('\(accountId)', 'Checking', 0, 0, 0, 16384)
            """,
            """
            INSERT INTO category_groups (
                id, name, is_income, sort_order, tombstone, hidden
            ) VALUES ('group-1', 'Daily', 0, 16384, 0, 0)
            """,
            """
            INSERT INTO categories (
                id, name, is_income, cat_group, sort_order, hidden, tombstone
            ) VALUES ('cat-1', 'Daily', 0, 'group-1', 16384, 0, 0)
            """,
        ]
        return (
            TestSchema.core
                + [
                    TestSchema.rules,
                    TestSchema.preferences,
                    TestSchema.messagesClock,
                    TestSchema.zeroBudgets,
                    TestSchema.reflectBudgets,
                    TestSchema.zeroBudgetMonths,
                    TestSchema.tags,
                    TestSchema.schedules,
                    TestSchema.schedulesNextDate,
                ]
                + seedRows
        ).joined(separator: ";\n")
    }

    private func makeServerClient(
        server: SyncServer,
        reachable: Bool
    ) async throws -> ActualServerClient {
        let session = StubTransport.session { request in
            guard reachable else { throw URLError(.notConnectedToInternet) }
            return server.respond(to: request)
        }
        let client = ActualServerClient(session: session)
        try await client.configure(serverURL: "https://budget.example.com")
        await client.setToken("test-token")
        return client
    }

    private func makeTransactionWriter(
        database: BudgetDatabase,
        serverClient: ActualServerClient
    ) async throws -> SyncClient {
        let client = SyncClient(serverClient: serverClient, nodeId: "89e0e8e90b203f9e")
        try await client.configure(database: database, fileId: "test-file", groupId: "test-group")
        return client
    }

    private func log(
        using writer: BudgetTransactionWriter,
        merchant: String
    ) async throws -> BudgetTransactionWriter.WriteResult {
        try await writer.logTransaction(
            accountId: "acct-1",
            amountCents: -820,
            rawMerchant: merchant,
            notes: nil,
            date: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    @Test func activeBudgetReusesTheStoreDatabaseAndSyncClient() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let server = SyncServer()
        let serverClient = try await makeServerClient(server: server, reachable: true)
        let syncClient = try await makeTransactionWriter(
            database: database,
            serverClient: serverClient
        )
        let originalCurrentBudget = UserDefaults.standard.object(forKey: "currentBudgetId")
        defer { restoreUserDefault("currentBudgetId", to: originalCurrentBudget) }
        let store = BudgetStore.previewInstance()
        store.currentBudgetId = "active-budget"
        store.configureForTesting(database: database, syncClient: syncClient)

        let first = try await store.transactionWriter(for: "active-budget")
        let second = try await store.transactionWriter(for: "active-budget")
        #expect(first === second)

        let result = try await log(using: first, merchant: "ACTIVE BUDGET COFFEE")
        #expect(try await database.fetchTransaction(id: result.transactionId) != nil)
        #expect(store.currentBudgetId == "active-budget")

        await store.closeBudgetConnectionsForTesting()
    }

    @Test func selectedBudgetWaitsForItsLoadInsteadOfOpeningSecondWriter() async throws {
        let originalCurrentBudget = UserDefaults.standard.object(forKey: "currentBudgetId")
        defer { restoreUserDefault("currentBudgetId", to: originalCurrentBudget) }
        let (store, fileManager, root) = makeFileBackedStore()
        defer { cleanup(root) }
        try seedBudget(id: "loading-budget", in: fileManager, sql: makeTargetBudgetSchema())
        let serverClient = try await makeServerClient(server: SyncServer(), reachable: false)
        store.setServerClientForTesting(serverClient)

        let gate = AsyncGate()
        let waitStarted = Gate()
        store.budgetLoadStartedForTesting = { await gate.pause() }
        store.budgetReadinessWaitStartedForTesting = { waitStarted.open() }
        store.currentBudgetId = "loading-budget"
        let loadTask = Task { await store.loadLocalBudget("loading-budget") }
        await gate.waitUntilEntered()

        let writerTask = Task { try await store.transactionWriter(for: "loading-budget") }
        await waitStarted.wait()
        await gate.release()
        let writer = try await writerTask.value
        let second = try await store.transactionWriter(for: "loading-budget")
        #expect(writer === second)
        await store.releaseTransactionWriter(for: "loading-budget")
        await store.releaseTransactionWriter(for: "loading-budget")
        await loadTask.value
        await store.closeBudgetConnectionsForTesting()
    }

    @Test func readinessWaitsForItsBudgetLoadToFinish() async throws {
        let originalCurrentBudget = UserDefaults.standard.object(forKey: "currentBudgetId")
        defer { restoreUserDefault("currentBudgetId", to: originalCurrentBudget) }
        let (store, fileManager, root) = makeFileBackedStore()
        defer { cleanup(root) }
        try seedBudget(id: "loading-budget", in: fileManager, sql: makeTargetBudgetSchema())
        let serverClient = try await makeServerClient(server: SyncServer(), reachable: false)
        store.setServerClientForTesting(serverClient)
        let loadGate = AsyncGate()
        let waitStarted = Gate()
        store.budgetLoadStartedForTesting = { await loadGate.pause() }
        store.budgetReadinessWaitStartedForTesting = { waitStarted.open() }
        store.currentBudgetId = "loading-budget"

        let load = Task { await store.loadLocalBudget("loading-budget") }
        await loadGate.waitUntilEntered()
        let readiness = Task {
            await store.ensureBudgetReady()
            return store.isReadyForShortcutRecovery(in: "loading-budget")
        }
        await waitStarted.wait()
        await loadGate.release()
        #expect(await readiness.value)
        await load.value
        await store.closeBudgetConnectionsForTesting()
    }

    @Test func selectedWriterServesShortcutAccountAndCategoryReads() async throws {
        let (store, fileManager, root) = makeFileBackedStore()
        defer { cleanup(root) }
        try seedBudget(id: "intent-reads", in: fileManager, sql: makeTargetBudgetSchema())
        let client = try await makeServerClient(server: SyncServer(), reachable: false)
        store.setServerClientForTesting(client)

        let writer = try await store.transactionWriter(for: "intent-reads")
        let accounts = await writer.accountsForIntent()
        let categories = await writer.categoriesForIntent()
        let mappings = await writer.cardMappingsForIntent()
        #expect(accounts.map(\.id) == ["acct-1"])
        #expect(categories.contains(where: { $0.id == "cat-1" }))
        #expect(mappings.isEmpty)
        #expect(store.currentBudgetId == nil)

        await store.releaseTransactionWriter(for: "intent-reads")
        await store.closeBudgetConnectionsForTesting()
    }

    @Test func successfulForegroundSyncClearsHeadlessInitialSyncMarker() async throws {
        let originalCurrentBudget = UserDefaults.standard.object(forKey: "currentBudgetId")
        defer { restoreUserDefault("currentBudgetId", to: originalCurrentBudget) }
        let (store, fileManager, root) = makeFileBackedStore()
        defer { cleanup(root) }
        let budgetID = "sync-recovery"
        let cloudID = "cloud-\(UUID().uuidString)"
        let flag = "shortcutInitialSync.\(cloudID)"
        defer { UserDefaults.standard.removeObject(forKey: flag) }
        try seedBudget(id: budgetID, in: fileManager, sql: makeTargetBudgetSchema())
        try JSONEncoder().encode(BudgetMetadata(
            id: budgetID, budgetName: "Recovered", cloudFileId: cloudID,
            groupId: "group-1", resetClock: nil, lastUploaded: nil, encryptKeyId: nil
        )).write(to: fileManager.metadataPath(for: budgetID))

        let server = SyncServer()
        let online = try await makeServerClient(server: server, reachable: true)
        store.setServerClientForTesting(online)
        UserDefaults.standard.set(true, forKey: flag)
        store.currentBudgetId = budgetID
        await store.loadLocalBudget(budgetID)
        #expect(UserDefaults.standard.bool(forKey: flag))

        await store.syncOnForeground()
        #expect(!UserDefaults.standard.bool(forKey: flag))

        let offline = try await makeServerClient(server: server, reachable: false)
        store.setServerClientForTesting(offline)
        #expect(try await store.localBudgetIDForIntent(cloudID) == budgetID)
        await store.closeBudgetConnectionsForTesting()
    }

    @Test func nonActiveBudgetWritesOnlyToItsOwnLocalFile() async throws {
        let (store, fileManager, root) = makeFileBackedStore()
        defer { cleanup(root) }
        try seedBudget(id: "travel-budget", in: fileManager, sql: makeTargetBudgetSchema())
        let server = SyncServer()
        let serverClient = try await makeServerClient(server: server, reachable: true)
        store.setServerClientForTesting(serverClient)

        let first = try await store.transactionWriter(for: "travel-budget")
        let second = try await store.transactionWriter(for: "travel-budget")
        #expect(first === second)

        let result = try await log(using: first, merchant: "TRAVEL COFFEE")
        let targetDatabase = try BudgetDatabase(
            path: fileManager.databasePath(for: "travel-budget")
        )

        #expect(result.synced)
        #expect(try await targetDatabase.fetchTransaction(id: result.transactionId) != nil)
        #expect(store.currentBudgetId == nil)

        await store.closeBudgetConnectionsForTesting()
    }

    @Test func shortcutWritesToSelectedBudgetWithoutSwitchingTheActiveBudget() async throws {
        let savedBudgetId = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer { restoreUserDefault("currentBudgetId", to: savedBudgetId) }
        let (store, fileManager, root) = makeFileBackedStore()
        defer { cleanup(root) }

        try seedBudget(
            id: "personal-budget",
            in: fileManager,
            sql: makeTargetBudgetSchema(accountId: "personal-account")
        )
        try seedBudget(
            id: "business-budget",
            in: fileManager,
            sql: makeTargetBudgetSchema(accountId: "business-account")
        )
        try JSONEncoder().encode(BudgetMetadata(
            id: "personal-budget",
            budgetName: "Personal",
            cloudFileId: "personal-cloud-file",
            groupId: "personal-group",
            resetClock: nil,
            lastUploaded: nil,
            encryptKeyId: nil
        )).write(to: fileManager.metadataPath(for: "personal-budget"))
        try JSONEncoder().encode(BudgetMetadata(
            id: "business-budget",
            budgetName: "Business",
            cloudFileId: "business-cloud-file",
            groupId: "business-group",
            resetClock: nil,
            lastUploaded: nil,
            encryptKeyId: nil
        )).write(to: fileManager.metadataPath(for: "business-budget"))

        let personalClient = try await makeServerClient(server: SyncServer(), reachable: true)
        store.setServerClientForTesting(personalClient)
        store.currentBudgetId = "personal-budget"
        await store.loadLocalBudget("personal-budget")

        let businessServer = SyncServer()
        let receivedTokens = Mutex<[String?]>([])
        let businessSession = StubTransport.session { request in
            receivedTokens.withLock {
                $0.append(request.value(forHTTPHeaderField: "X-ACTUAL-TOKEN"))
            }
            return businessServer.respond(to: request)
        }
        let businessClient = ActualServerClient(session: businessSession)
        try await businessClient.configure(serverURL: "https://budget.example.com")
        store.setServerClientForTesting(businessClient)

        // Model the cold-start case: the selected non-active budget becomes
        // writable only after the saved server session has finished configuring.
        let sessionGate = Gate()
        let sessionStarted = Gate()
        let sessionTask = Task {
            sessionStarted.open()
            await sessionGate.wait()
            await businessClient.setToken("business-token")
        }
        await sessionStarted.wait()
        store.setSavedSessionTaskForTesting(sessionTask)
        let writerReachedSessionBarrier = Gate()
        store.savedSessionWaitStartedForTesting = {
            writerReachedSessionBarrier.open()
        }

        var intent = LogTransactionIntent()
        // The picker serializes the stable cloud ID, not the local file ID.
        intent.budget = BudgetEntity(id: "business-cloud-file", name: "Business")
        intent.account = AccountEntity(
            id: AccountEntity.scopedID(budgetID: "business-cloud-file", accountID: "business-account"),
            name: "Business Checking"
        )
        intent.amount = "8.20"
        intent.payee = "Business Merchant"
        intent.date = Date(timeIntervalSince1970: 1_750_000_000)

        let performTask = Task {
            try await TransactionLogNotifier.$center.withValue(DeniedNotificationCenter()) {
                try await intent.perform(using: store)
            }
        }
        await writerReachedSessionBarrier.wait()
        try await Task.sleep(for: .milliseconds(50))

        let businessDatabase = try BudgetDatabase(
            path: fileManager.databasePath(for: "business-budget")
        )
        #expect(try await businessDatabase.fetchTransactions().isEmpty)
        #expect(receivedTokens.withLock { $0.isEmpty })

        sessionGate.open()
        _ = try await performTask.value

        let personalDatabase = try BudgetDatabase(
            path: fileManager.databasePath(for: "personal-budget")
        )
        let businessTransactions = try await businessDatabase.fetchTransactions()
        let personalTransactions = try await personalDatabase.fetchTransactions()

        #expect(store.currentBudgetId == "personal-budget")
        #expect(personalTransactions.isEmpty)
        #expect(businessTransactions.count == 1)
        #expect(businessTransactions.first?.accountId == "business-account")
        #expect(businessTransactions.first?.amount == -820)
        #expect(!receivedTokens.withLock { $0.isEmpty })
        #expect(receivedTokens.withLock { $0.allSatisfy { $0 == "business-token" } })

        await store.closeBudgetConnectionsForTesting()
    }

    @Test func activeWriterLeasesReleaseWithoutClosingTheStoresSyncClient() async throws {
        let savedBudgetId = UserDefaults.standard.object(forKey: "currentBudgetId")
        defer { restoreUserDefault("currentBudgetId", to: savedBudgetId) }
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let serverClient = try await makeServerClient(server: SyncServer(), reachable: true)
        let syncClient = try await makeTransactionWriter(database: database, serverClient: serverClient)
        let store = BudgetStore.previewInstance()
        store.currentBudgetId = "active-budget"
        store.configureForTesting(database: database, syncClient: syncClient)

        let first = try await store.transactionWriter(for: "active-budget")
        let second = try await store.transactionWriter(for: "active-budget")
        await store.releaseTransactionWriter(for: "active-budget")
        await store.releaseTransactionWriter(for: "active-budget")

        let reopened = try await store.transactionWriter(for: "active-budget")
        #expect(first === second)
        #expect(first !== reopened)
        let result = try await log(using: reopened, merchant: "ACTIVE AFTER CLOSE")
        #expect(try await database.fetchTransaction(id: result.transactionId) != nil)
        await store.releaseTransactionWriter(for: "active-budget")
        await store.closeBudgetConnectionsForTesting()
    }

    @Test func rapidTapsToDifferentBudgetsUseIndependentWriters() async throws {
        let (store, fileManager, root) = makeFileBackedStore()
        defer { cleanup(root) }
        let schema = makeTargetBudgetSchema()
        try seedBudget(id: "home-budget", in: fileManager, sql: schema)
        try seedBudget(id: "travel-budget", in: fileManager, sql: schema)
        let server = SyncServer()
        let serverClient = try await makeServerClient(server: server, reachable: false)
        store.setServerClientForTesting(serverClient)

        async let homeWriter = store.transactionWriter(for: "home-budget")
        async let duplicateHomeWriter = store.transactionWriter(for: "home-budget")
        async let travelWriter = store.transactionWriter(for: "travel-budget")
        let (home, duplicateHome, travel) = try await (
            homeWriter, duplicateHomeWriter, travelWriter
        )
        #expect(home === duplicateHome)

        async let homeResult = log(using: home, merchant: "HOME COFFEE")
        async let travelResult = log(using: travel, merchant: "TRAVEL COFFEE")
        let (homeWrite, travelWrite) = try await (homeResult, travelResult)

        let homeDatabase = try BudgetDatabase(path: fileManager.databasePath(for: "home-budget"))
        let travelDatabase = try BudgetDatabase(
            path: fileManager.databasePath(for: "travel-budget")
        )
        #expect(try await homeDatabase.fetchTransaction(id: homeWrite.transactionId) != nil)
        #expect(try await travelDatabase.fetchTransaction(id: travelWrite.transactionId) != nil)
        #expect(homeWrite.transactionId != travelWrite.transactionId)
        #expect(store.currentBudgetId == nil)

        await store.closeBudgetConnectionsForTesting()
    }

    @Test func overlappingShortcutWritersStayOpenUntilTheLastLeaseIsReleased() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let serverClient = try await makeServerClient(server: SyncServer(), reachable: false)
        let syncClient = try await makeTransactionWriter(
            database: database, serverClient: serverClient
        )
        let writer = BudgetTransactionWriter(
            database: database,
            syncClient: syncClient,
            budgetId: "shared-budget",
            currencyCode: "USD",
            numberFormat: .commaDot,
            suggestCategoryFromPayeeHistory: true,
            ownsResources: true
        )
        let registry = BudgetTransactionWriterRegistry()
        let first = try await registry.writer(for: "shared-budget") { writer }
        let second = try await registry.writer(for: "shared-budget") { writer }
        #expect(first === second)

        // The first Wallet run completes while the second is still resolving.
        await registry.release(budgetId: "shared-budget")
        let stillOpen = try await registry.writer(for: "shared-budget") {
            throw TransactionLogger.LoggerError.noBudgetLoaded
        }
        #expect(stillOpen === writer)

        await registry.release(budgetId: "shared-budget")
        await registry.release(budgetId: "shared-budget")
        await #expect(throws: TransactionLogger.LoggerError.noBudgetLoaded) {
            try await writer.logTransaction(
                accountId: "acct-1", amountCents: -100,
                rawMerchant: "Coffee", notes: nil, date: Date()
            )
        }
    }

    @Test func incorrectBudgetScopedCategoryFailsWithoutSaving() async throws {
        let (store, fileManager, root) = makeFileBackedStore()
        defer { cleanup(root) }
        try seedBudget(id: "target-budget", in: fileManager, sql: makeTargetBudgetSchema())
        let serverClient = try await makeServerClient(server: SyncServer(), reachable: false)
        store.setServerClientForTesting(serverClient)

        var intent = LogTransactionIntent()
        intent.budget = BudgetEntity(id: "target-budget", name: "Target")
        intent.account = AccountEntity(
            id: AccountEntity.scopedID(budgetID: "target-budget", accountID: "acct-1"),
            name: "Checking"
        )
        intent.category = CategoryEntity(
            id: CategoryEntity.scopedID(budgetID: "other-budget", categoryID: "cat-1"),
            name: "Daily"
        )
        intent.amount = "8.20"
        intent.payee = "Coffee"

        do {
            _ = try await TransactionLogNotifier.$center.withValue(DeniedNotificationCenter()) {
                try await intent.perform(using: store)
            }
            Issue.record("A category belonging to another budget must reject the shortcut")
        } catch LogTransactionError.categoryUnavailable {
            // The explicit category must never be silently replaced by payee history.
        } catch {
            Issue.record("Unexpected shortcut error: \(error)")
        }

        let db = try BudgetDatabase(path: fileManager.databasePath(for: "target-budget"))
        #expect(try await db.fetchTransactions().isEmpty)
        await store.closeBudgetConnectionsForTesting()
    }

    @Test func deletedBudgetScopedCategoryFailsWithoutSaving() async throws {
        let (store, fileManager, root) = makeFileBackedStore()
        defer { cleanup(root) }
        try seedBudget(id: "target-budget", in: fileManager, sql: makeTargetBudgetSchema())
        let serverClient = try await makeServerClient(server: SyncServer(), reachable: false)
        store.setServerClientForTesting(serverClient)

        var intent = LogTransactionIntent()
        intent.budget = BudgetEntity(id: "target-budget", name: "Target")
        intent.account = AccountEntity(
            id: AccountEntity.scopedID(budgetID: "target-budget", accountID: "acct-1"),
            name: "Checking"
        )
        intent.category = CategoryEntity(
            id: CategoryEntity.scopedID(budgetID: "target-budget", categoryID: "deleted-category"),
            name: "Deleted"
        )
        intent.amount = "8.20"
        intent.payee = "Coffee"

        do {
            _ = try await TransactionLogNotifier.$center.withValue(DeniedNotificationCenter()) {
                try await intent.perform(using: store)
            }
            Issue.record("A deleted explicitly selected category must reject the shortcut")
        } catch LogTransactionError.categoryUnavailable {
            // Keep the old unscoped fallback, but reject stale scoped choices.
        } catch {
            Issue.record("Unexpected shortcut error: \(error)")
        }
        let db = try BudgetDatabase(path: fileManager.databasePath(for: "target-budget"))
        #expect(try await db.fetchTransactions().isEmpty)
        await store.closeBudgetConnectionsForTesting()
    }

    @Test func notificationRecoverySwitchesOnlyOnExplicitRequest() async throws {
        let (store, fileManager, root) = makeFileBackedStore()
        defer { cleanup(root) }
        try seedBudget(id: "recovery-budget", in: fileManager, sql: makeTargetBudgetSchema())
        #expect(store.currentBudgetId == nil)
        #expect(store.nameForShortcutRecoveryBudget("recovery-budget") != nil)
        #expect(!store.isReadyForShortcutRecovery(in: "recovery-budget"))

        let switched = await store.switchToShortcutRecoveryBudget("recovery-budget")
        #expect(switched)
        #expect(store.currentBudgetId == "recovery-budget")
        #expect(store.isReadyForShortcutRecovery(in: "recovery-budget"))
        #expect(!store.isReadyForShortcutRecovery(in: "another-budget"))

        await store.closeBudgetConnectionsForTesting()
    }

    @Test func registryCloseAndRejectBlocksSubsequentWriters() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let server = SyncServer()
        let serverClient = try await makeServerClient(server: server, reachable: false)
        let syncClient = try await makeTransactionWriter(
            database: database,
            serverClient: serverClient
        )
        let writer = BudgetTransactionWriter(
            database: database,
            syncClient: syncClient,
            budgetId: "deleting-budget",
            currencyCode: "USD",
            numberFormat: .commaDot,
            suggestCategoryFromPayeeHistory: true,
            ownsResources: true
        )
        let registry = BudgetTransactionWriterRegistry()
        _ = try await registry.writer(for: "deleting-budget") { writer }

        await registry.closeAndReject(budgetId: "deleting-budget")
        await #expect(throws: TransactionLogger.LoggerError.noBudgetLoaded) {
            try await registry.writer(for: "deleting-budget") { writer }
        }

        await registry.allowWriters(for: "deleting-budget")
        await #expect(throws: TransactionLogger.LoggerError.transactionAlreadyExists) {
            try await registry.writer(for: "deleting-budget") {
                throw TransactionLogger.LoggerError.transactionAlreadyExists
            }
        }
        await syncClient.cancelPendingSync()
    }

    @Test func budgetNotDownloadedOnThisDeviceCannotBeTargeted() async throws {
        let (store, _, root) = makeFileBackedStore()
        defer { cleanup(root) }

        await #expect(throws: TransactionLogger.LoggerError.noBudgetLoaded) {
            try await store.transactionWriter(for: "remote-only-budget")
        }
        #expect(store.currentBudgetId == nil)
    }

    @Test func removedBudgetCannotBeOpenedOrWrittenAgain() async throws {
        let (store, fileManager, root) = makeFileBackedStore()
        defer { cleanup(root) }
        try seedBudget(id: "deleted-budget", in: fileManager, sql: makeTargetBudgetSchema())
        let server = SyncServer()
        let serverClient = try await makeServerClient(server: server, reachable: false)
        store.setServerClientForTesting(serverClient)

        let writer = try await store.transactionWriter(for: "deleted-budget")
        await writer.close()
        await store.removeLocalBudget(cloudFileId: "cf-1")

        #expect(!fileManager.budgetExists("deleted-budget"))
        await #expect(throws: TransactionLogger.LoggerError.noBudgetLoaded) {
            try await store.transactionWriter(for: "deleted-budget")
        }
        await store.closeBudgetConnectionsForTesting()
    }

    @Test func offlineNonActiveWriteSyncsWhenThatBudgetIsLoaded() async throws {
        let originalCurrentBudget = UserDefaults.standard.object(forKey: "currentBudgetId")
        defer { restoreUserDefault("currentBudgetId", to: originalCurrentBudget) }
        let (store, fileManager, root) = makeFileBackedStore()
        defer { cleanup(root) }
        try seedBudget(id: "offline-budget", in: fileManager, sql: makeTargetBudgetSchema())

        let offlineServer = SyncServer()
        let offlineClient = try await makeServerClient(server: offlineServer, reachable: false)
        store.setServerClientForTesting(offlineClient)
        let writer = try await store.transactionWriter(for: "offline-budget")
        let result = try await log(using: writer, merchant: "OFFLINE COFFEE")

        #expect(!result.synced)
        let targetDatabase = try BudgetDatabase(
            path: fileManager.databasePath(for: "offline-budget")
        )
        #expect(try await targetDatabase.fetchTransaction(id: result.transactionId) != nil)
        await store.closeTransactionWritersForTesting()

        let onlineServer = SyncServer()
        let onlineClient = try await makeServerClient(server: onlineServer, reachable: true)
        store.setServerClientForTesting(onlineClient)
        store.currentBudgetId = "offline-budget"
        await store.loadLocalBudget("offline-budget")
        await store.syncOnForeground()

        let hasPendingWrites = await store.hasPendingLocalWrites()
        #expect(!hasPendingWrites)
        await store.closeBudgetConnectionsForTesting()
    }
}
