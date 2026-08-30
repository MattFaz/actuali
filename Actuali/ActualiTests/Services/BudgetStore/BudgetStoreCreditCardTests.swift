import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreCreditCardTests {

    private func makeStore() throws -> (BudgetStore, BudgetFileManager, String, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-tests-\(UUID().uuidString)", isDirectory: true)
        let manager = BudgetFileManager(rootDirectoryForTesting: root)
        let store = BudgetStore.previewInstance()
        store.setFileManagerForTesting(manager)
        return (store, manager, "budget-\(UUID().uuidString)", root)
    }

    private func seedBudget(id: String, in manager: BudgetFileManager) async throws {
        let dir = manager.budgetDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: id).path)
        try await dbQueue.write { db in
            try db.execute(sql: BudgetStoreInitialSyncTests.upstreamSchema)
        }
        try JSONEncoder().encode(BudgetMetadata(
            id: id, budgetName: "Seed", cloudFileId: "cf-1", groupId: "group-1",
            resetClock: nil, lastUploaded: nil, encryptKeyId: nil
        )).write(to: manager.metadataPath(for: id))
    }

    @Test func legacyDefaultsMigrateOnLoad() async throws {
        let (store, manager, budgetId, root) = try makeStore()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removeObject(forKey: "creditCardStatementDays_\(budgetId)")
            UserDefaults.standard.removeObject(forKey: "creditCardDueOffsets_\(budgetId)")
            UserDefaults.standard.removeObject(forKey: "creditCardLimits_\(budgetId)")
        }

        try await seedBudget(id: budgetId, in: manager)

        // Seed legacy UserDefaults keys
        UserDefaults.standard.set(["acct_chase": 18], forKey: "creditCardStatementDays_\(budgetId)")
        UserDefaults.standard.set(["acct_chase": 25], forKey: "creditCardDueOffsets_\(budgetId)")
        UserDefaults.standard.set(["acct_chase": 500000], forKey: "creditCardLimits_\(budgetId)")

        await store.loadLocalBudget(budgetId)

        #expect(store.creditCardStatementDays["acct_chase"] == 18)
        #expect(store.creditCardDueOffsets["acct_chase"] == 25)
        #expect(store.creditCardLimits["acct_chase"] == 500000)

        // Legacy UserDefaults keys must be erased so removed cards don't resurrect
        #expect(UserDefaults.standard.dictionary(forKey: "creditCardStatementDays_\(budgetId)") == nil)
        #expect(UserDefaults.standard.dictionary(forKey: "creditCardDueOffsets_\(budgetId)") == nil)
        #expect(UserDefaults.standard.dictionary(forKey: "creditCardLimits_\(budgetId)") == nil)
    }

    @Test func budgetStoreReflectsSyncedCardsFromDatabase() async throws {
        let (store, manager, budgetId, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await seedBudget(id: budgetId, in: manager)

        // Insert directly into preferences table
        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: budgetId).path)
        let config = CreditCardConfig(statementDay: 20, dueOffsetDays: 30, limit: 1000000)
        let data = try JSONEncoder().encode(config)
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: ["actuali:credit_card:acct_apple", String(data: data, encoding: .utf8)]
            )
        }

        await store.loadLocalBudget(budgetId)

        #expect(store.creditCardStatementDays["acct_apple"] == 20)
        #expect(store.creditCardDueOffsets["acct_apple"] == 30)
        #expect(store.creditCardLimits["acct_apple"] == 1000000)
    }

    @Test func cardsAreScopedPerBudgetOnLoad() async throws {
        let (store, manager, budgetA, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let budgetB = "budget-\(UUID().uuidString)"

        try await seedBudget(id: budgetA, in: manager)
        try await seedBudget(id: budgetB, in: manager)

        let dbQueueA = try DatabaseQueue(path: manager.databasePath(for: budgetA).path)
        let configA = CreditCardConfig(statementDay: 18, dueOffsetDays: 25, limit: 500000)
        let dataA = try JSONEncoder().encode(configA)
        try await dbQueueA.write { db in
            try db.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: ["actuali:credit_card:acct_chase", String(data: dataA, encoding: .utf8)]
            )
        }

        await store.loadLocalBudget(budgetA)
        #expect(store.creditCardStatementDays["acct_chase"] == 18)

        await store.loadLocalBudget(budgetB)
        #expect(store.creditCardStatementDays.isEmpty)

        // Reload budget A and assert configs return
        await store.loadLocalBudget(budgetA)
        #expect(store.creditCardStatementDays["acct_chase"] == 18)
    }

    @Test func setCreditCardPersistsThroughSync() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let queue = try DatabaseQueue(path: tempURL.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
                CREATE TABLE messages_crdt (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL UNIQUE, dataset TEXT NOT NULL, row TEXT NOT NULL, column TEXT NOT NULL, value BLOB NOT NULL);
            """)
        }
        let database = try BudgetDatabase(path: tempURL)
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")

        let store = BudgetStore.previewInstance()
        store.currentBudgetId = "test-budget"
        store.configureForTesting(database: database, syncClient: syncClient)

        await store.setCreditCard(accountId: "acct_chase", statementDay: 18, dueOffsetDays: 25, limit: 500_000)

        #expect(store.creditCardStatementDays["acct_chase"] == 18)
        #expect(store.creditCardDueOffsets["acct_chase"] == 25)
        #expect(store.creditCardLimits["acct_chase"] == 500_000)

        let configs = try await database.fetchCreditCardConfigs()
        #expect(configs["acct_chase"]?.statementDay == 18)
        #expect(configs["acct_chase"]?.dueOffsetDays == 25)
        #expect(configs["acct_chase"]?.limit == 500_000)
    }
}
