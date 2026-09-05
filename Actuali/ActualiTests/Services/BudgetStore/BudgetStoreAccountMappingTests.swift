import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreAccountMappingTests {

    /// Runs `body` with a store whose budget is `test-budget`, then restores
    /// the UserDefaults state the store's `currentBudgetId.didSet` persists.
    private func withMappingStore(_ body: @MainActor (BudgetStore) async -> Void) async {
        let savedDefault = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer {
            UserDefaults.standard.removeObject(forKey: "cardAccountMappings_test-budget")
            UserDefaults.standard.set(savedDefault, forKey: "currentBudgetId")
        }
        let store = BudgetStore.previewInstance()
        store.currentBudgetId = "test-budget"
        await body(store)
    }

    private func makeStore() throws -> (BudgetStore, BudgetFileManager, String, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func account(_ id: String, _ name: String, closed: Bool = false) -> Account {
        Account(id: id, name: name, type: .checking, offBudget: false, closed: closed,
                sortOrder: 0, balance: 0)
    }

    @Test func legacyDefaultsMigrateOnLoad() async throws {
        let (store, manager, budgetId, root) = try makeStore()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removeObject(forKey: "cardAccountMappings_\(budgetId)")
        }

        try await seedBudget(id: budgetId, in: manager)

        UserDefaults.standard.set(
            ["1234": "acct_hsbc", "9876": "acct_hdfc", " 5678 ": "acct_chase", "  ": "acct_blank"],
            forKey: "cardAccountMappings_\(budgetId)"
        )

        await store.loadLocalBudget(budgetId)

        #expect(store.cardAccountMappings["1234"] == "acct_hsbc")
        #expect(store.cardAccountMappings["9876"] == "acct_hdfc")
        #expect(store.cardAccountMappings["5678"] == "acct_chase")
        #expect(store.cardAccountMappings[" 5678 "] == nil)
        #expect(store.cardAccountMappings[""] == nil)
        #expect(store.cardAccountMappings["  "] == nil)

        // Legacy UserDefaults key must be erased
        #expect(UserDefaults.standard.dictionary(forKey: "cardAccountMappings_\(budgetId)") == nil)
    }

    @Test func setCardAccountMappingPersistsThroughSync() async throws {
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

        await store.setCardAccountMapping(keyword: "1234", accountId: "acct_chase")

        #expect(store.cardAccountMappings["1234"] == "acct_chase")

        var fetched = try await database.fetchCardAccountMappings()
        #expect(fetched["1234"] == "acct_chase")

        // Removing mapping
        await store.setCardAccountMapping(keyword: "1234", accountId: nil)
        #expect(store.cardAccountMappings["1234"] == nil)

        fetched = try await database.fetchCardAccountMappings()
        #expect(fetched.isEmpty)
    }

    @Test func deleteCardAccountMappingsRemovesEveryKeyword() async throws {
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

        await store.setCardAccountMapping(keyword: "1234", accountId: "acct_chase")
        await store.setCardAccountMapping(keyword: "HSBC", accountId: "acct_hsbc")

        // Deleting non-existent keywords should be a safe no-op
        await store.deleteCardAccountMappings(keywords: ["UNKNOWN"])
        #expect(store.cardAccountMappings.count == 2)

        await store.deleteCardAccountMappings(keywords: [" 1234 ", "HSBC"])

        #expect(store.cardAccountMappings.isEmpty)
        let fetched = try await database.fetchCardAccountMappings()
        #expect(fetched.isEmpty)
    }

    @Test func cardAccountMappingsScopedPerBudget() async throws {
        let (store, manager, budgetA, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let budgetB = "budget-\(UUID().uuidString)"

        try await seedBudget(id: budgetA, in: manager)
        try await seedBudget(id: budgetB, in: manager)

        let dbQueueA = try DatabaseQueue(path: manager.databasePath(for: budgetA).path)
        let dataA = try JSONEncoder().encode(["1234": "acct_chase"])
        let jsonA = String(decoding: dataA, as: UTF8.self)
        try await dbQueueA.write { db in
            try db.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: [BudgetDatabase.cardMappingsPreferenceKey, jsonA]
            )
        }

        await store.loadLocalBudget(budgetA)
        #expect(store.cardAccountMappings["1234"] == "acct_chase")

        await store.loadLocalBudget(budgetB)
        #expect(store.cardAccountMappings.isEmpty)

        await store.loadLocalBudget(budgetA)
        #expect(store.cardAccountMappings["1234"] == "acct_chase")
    }

    @Test func resolveAccountIdMatchesMappingKeyword() async {
        await withMappingStore { store in
            store.accounts = [account("acct1", "Checking")]
            store.cardAccountMappings = ["1234": "acct1"]

            let resolved = await store.resolveAccountId(hint: "HSBC Credit Card 1234")
            #expect(resolved == "acct1")
        }
    }

    @Test func resolveAccountIdPrefersLongestMappingKey() async {
        await withMappingStore { store in
            store.accounts = [account("acct1", "Checking"), account("acct2", "Savings")]
            store.cardAccountMappings = ["12": "acct1", "1234": "acct2"]

            let resolved = await store.resolveAccountId(hint: "Card 1234")
            #expect(resolved == "acct2")
        }
    }

    @Test func resolveAccountIdDoesNotMatchPartialHintAgainstMappingKey() async {
        await withMappingStore { store in
            store.accounts = [account("acct1", "Checking")]
            store.cardAccountMappings = ["1234": "acct1"]

            // A hint that's a fragment of a keyword must not match — the
            // reverse direction would let "4" route money to "1234"'s account.
            let resolved = await store.resolveAccountId(hint: "4")
            #expect(resolved == nil)
        }
    }

    @Test func resolveAccountIdMatchesAccountNameByWholeWords() async {
        await withMappingStore { store in
            store.accounts = [account("acct1", "Checking")]
            let resolved = await store.resolveAccountId(hint: "Checking Account")
            #expect(resolved == "acct1")
        }
    }

    @Test func resolveAccountIdDoesNotMatchNameInsideLargerWord() async {
        await withMappingStore { store in
            store.accounts = [account("acct1", "Cash")]
            // "cashback" contains "cash" as a substring, not as a word.
            let resolved = await store.resolveAccountId(hint: "HSBC cashback card")
            #expect(resolved == nil)
        }
    }

    @Test func resolveAccountIdReturnsNilWhenNameMatchIsAmbiguous() async {
        await withMappingStore { store in
            store.accounts = [account("acct1", "Card"), account("acct2", "HSBC")]
            // Both names appear as words in the hint — refuse to guess so the
            // intent falls back to the default account or a visible error.
            let resolved = await store.resolveAccountId(hint: "HSBC credit card")
            #expect(resolved == nil)
        }
    }

    @Test func resolveAccountIdReturnsNilForUnknownHint() async {
        await withMappingStore { store in
            store.accounts = [account("acct1", "Checking")]
            let resolved = await store.resolveAccountId(hint: "NonExistentBank9999")
            #expect(resolved == nil)
        }
    }

    @Test func resolveAccountIdFallsBackToDatabaseFileWhenDatabaseIsNil() async throws {
        let (store, manager, budgetId, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await seedBudget(id: budgetId, in: manager)

        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: budgetId).path)
        let data = try JSONEncoder().encode(["1234": "acct_hsbc"])
        let json = String(decoding: data, as: UTF8.self)
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO accounts (id, name, type, offbudget, closed, tombstone) VALUES (?, ?, ?, 0, 0, 0)",
                arguments: ["acct_hsbc", "HSBC Checking", "checking"]
            )
            try db.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: [BudgetDatabase.cardMappingsPreferenceKey, json]
            )
        }

        store.currentBudgetId = budgetId

        let resolved = await store.resolveAccountId(hint: "1234")
        #expect(resolved == "acct_hsbc")
    }

    // The static entry point is what the pending-import edit form calls;
    // these cover its edges without a store.

    @Test func resolveAccountIdSkipsMappingToClosedAccount() {
        let resolved = BudgetStore.resolveAccountId(
            hint: "1234",
            accounts: [account("acct1", "HSBC", closed: true), account("acct2", "Cash")],
            cardMappings: ["1234": "acct1"])
        #expect(resolved == nil)
    }

    @Test func resolveAccountIdReturnsNilForBlankHint() {
        let resolved = BudgetStore.resolveAccountId(
            hint: "  ",
            accounts: [account("acct1", "Cash")],
            cardMappings: [:])
        #expect(resolved == nil)
    }
}
