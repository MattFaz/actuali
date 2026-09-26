import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreLoanTests {
    private let config = LoanConfig(
        originalBalance: 2_200_000,
        annualRatePercent: 6,
        minimumPayment: 36500,
        escrowOrFees: nil
    )

    private func makeStore() throws -> (BudgetStore, BudgetFileManager, String, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loan-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func seedLoan(_ config: LoanConfig, accountId: String, budgetId: String,
                          in manager: BudgetFileManager) async throws {
        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: budgetId).path)
        let json = try String(decoding: JSONEncoder().encode(config), as: UTF8.self)
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: ["actuali:loan:\(accountId)", json]
            )
        }
    }

    @Test func budgetStoreReflectsSyncedLoansFromDatabase() async throws {
        let (store, manager, budgetId, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await seedBudget(id: budgetId, in: manager)
        try await seedLoan(config, accountId: "acct_car", budgetId: budgetId, in: manager)

        await store.loadLocalBudget(budgetId)

        #expect(store.loanConfigs["acct_car"] == config)
    }

    @Test func loansAreScopedPerBudgetOnLoad() async throws {
        let (store, manager, budgetA, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let budgetB = "budget-\(UUID().uuidString)"

        try await seedBudget(id: budgetA, in: manager)
        try await seedBudget(id: budgetB, in: manager)
        try await seedLoan(config, accountId: "acct_car", budgetId: budgetA, in: manager)

        await store.loadLocalBudget(budgetA)
        #expect(store.loanConfigs["acct_car"] == config)

        await store.loadLocalBudget(budgetB)
        #expect(store.loanConfigs.isEmpty)

        await store.loadLocalBudget(budgetA)
        #expect(store.loanConfigs["acct_car"] == config)
    }

    /// Points the store at a throwaway budget with a test database and sync client.
    private func withStore(_ body: @MainActor (BudgetStore, BudgetDatabase) async throws -> Void) async throws {
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
        store.configureForTesting(database: database, syncClient: syncClient)
        store.currentBudgetId = "test-budget"
        try await body(store, database)
    }

    @Test func setLoanPersistsAndClears() async throws {
        try await withStore { store, database in
            await store.setLoan(accountId: "acct_car", config: config)

            #expect(store.loanConfigs["acct_car"] == config)
            let stored = try await database.fetchLoanConfigs()
            #expect(stored["acct_car"] == config)

            await store.setLoan(accountId: "acct_car", config: nil)

            #expect(store.loanConfigs["acct_car"] == nil)
            let cleared = try await database.fetchLoanConfigs()
            #expect(cleared["acct_car"] == nil)
        }
    }

    // MARK: - Active loans

    /// A closed account keeps its stored config — reopening restores the loan —
    /// but drops out of everything that displays loans, through one predicate
    /// rather than each surface re-deciding.
    @Test func closedAccountsKeepTheirConfigButDropOutOfTheActiveList() async throws {
        try await withStore { store, _ in
            store.accounts = [
                Account(id: "acct_open", name: "Car", type: .debt, offBudget: true, closed: false, sortOrder: 0, balance: -100),
                Account(id: "acct_closed", name: "Paid Car", type: .debt, offBudget: true, closed: true, sortOrder: 1, balance: 0),
            ]
            await store.setLoan(accountId: "acct_open", config: config)
            await store.setLoan(accountId: "acct_closed", config: config)

            #expect(store.loanConfigs.count == 2)
            #expect(store.activeLoanConfigs.keys.sorted() == ["acct_open"])
            #expect(store.activeLoanConfig(for: "acct_open") == config)
            #expect(store.activeLoanConfig(for: "acct_closed") == nil)
        }
    }

    @Test func activeLoanConfigIsNilForAnAccountThatNoLongerExists() async throws {
        try await withStore { store, _ in
            store.accounts = []
            await store.setLoan(accountId: "acct_car", config: config)

            #expect(store.loanConfigs["acct_car"] == config)
            #expect(store.activeLoanConfig(for: "acct_car") == nil)
            #expect(store.activeLoanConfigs.isEmpty)
        }
    }
}
