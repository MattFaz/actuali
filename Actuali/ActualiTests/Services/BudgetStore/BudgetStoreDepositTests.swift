import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreDepositTests {
    private let config = DepositConfig(
        kind: .fixed,
        amount: 10_000_000,
        annualRatePercent: 7,
        compounding: .quarterly,
        openedOn: DayDate(year: 2026, month: 1, day: 15),
        termMonths: 60
    )

    private func makeStore() throws -> (BudgetStore, BudgetFileManager, String, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deposit-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func seedDeposit(
        _ config: DepositConfig, accountId: String, budgetId: String,
        in manager: BudgetFileManager
    ) async throws {
        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: budgetId).path)
        let json = try String(decoding: JSONEncoder().encode(config), as: UTF8.self)
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: ["actuali:deposit:\(accountId)", json]
            )
        }
    }

    @Test func budgetStoreReflectsSyncedDepositsFromDatabase() async throws {
        let (store, manager, budgetId, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await seedBudget(id: budgetId, in: manager)
        try await seedDeposit(config, accountId: "acct_fd", budgetId: budgetId, in: manager)

        await store.loadLocalBudget(budgetId)

        #expect(store.depositConfigs["acct_fd"] == config)
    }

    @Test func depositsAreScopedPerBudgetOnLoad() async throws {
        let (store, manager, budgetA, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let budgetB = "budget-\(UUID().uuidString)"

        try await seedBudget(id: budgetA, in: manager)
        try await seedBudget(id: budgetB, in: manager)
        try await seedDeposit(config, accountId: "acct_fd", budgetId: budgetA, in: manager)

        await store.loadLocalBudget(budgetA)
        #expect(store.depositConfigs["acct_fd"] == config)

        await store.loadLocalBudget(budgetB)
        #expect(store.depositConfigs.isEmpty)

        await store.loadLocalBudget(budgetA)
        #expect(store.depositConfigs["acct_fd"] == config)
    }

    /// Points the store at a throwaway budget with a test database and sync
    /// client. `currentBudgetId` is set explicitly because `setDeposit` guards
    /// on it — the same guard that silently swallowed writes in the loan
    /// payment fixture until it was set.
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

    @Test func setDepositPersistsAndClears() async throws {
        try await withStore { store, database in
            await store.setDeposit(accountId: "acct_fd", config: config)

            #expect(store.depositConfigs["acct_fd"] == config)
            let stored = try await database.fetchDepositConfigs()
            #expect(stored["acct_fd"] == config)

            await store.setDeposit(accountId: "acct_fd", config: nil)

            #expect(store.depositConfigs["acct_fd"] == nil)
            let cleared = try await database.fetchDepositConfigs()
            #expect(cleared["acct_fd"] == nil)
        }
    }

    /// Deposits, loans and cards ride the same preferences table; setting one
    /// must not disturb another on the same account.
    @Test func aDepositAndALoanCanShareAnAccountWithoutClobbering() async throws {
        try await withStore { store, database in
            let loan = LoanConfig(
                originalBalance: 2_200_000, annualRatePercent: 6,
                minimumPayment: 36500, escrowOrFees: nil
            )
            await store.setDeposit(accountId: "acct_both", config: config)
            await store.setLoan(accountId: "acct_both", config: loan)

            #expect(store.depositConfigs["acct_both"] == config)
            #expect(store.loanConfigs["acct_both"] == loan)

            let deposits = try await database.fetchDepositConfigs()
            let loans = try await database.fetchLoanConfigs()
            #expect(deposits["acct_both"] == config)
            #expect(loans["acct_both"] == loan)
        }
    }

    // MARK: - Active deposits

    /// A closed account keeps its stored config — reopening restores the
    /// deposit — but drops out of everything that displays deposits, through
    /// one predicate rather than each surface re-deciding.
    @Test func closedAccountsKeepTheirConfigButDropOutOfTheActiveList() async throws {
        try await withStore { store, _ in
            store.accounts = [
                Account(id: "acct_open", name: "FD", type: .savings, offBudget: true, closed: false, sortOrder: 0, balance: 10_000_000),
                Account(id: "acct_closed", name: "Matured FD", type: .savings, offBudget: true, closed: true, sortOrder: 1, balance: 0),
            ]
            await store.setDeposit(accountId: "acct_open", config: config)
            await store.setDeposit(accountId: "acct_closed", config: config)

            #expect(store.depositConfigs.count == 2)
            #expect(store.activeDepositConfigs.keys.sorted() == ["acct_open"])
            #expect(store.activeDepositConfig(for: "acct_open") == config)
            #expect(store.activeDepositConfig(for: "acct_closed") == nil)
        }
    }

    @Test func activeDepositConfigIsNilForAnAccountThatNoLongerExists() async throws {
        try await withStore { store, _ in
            store.accounts = []
            await store.setDeposit(accountId: "acct_fd", config: config)

            #expect(store.depositConfigs["acct_fd"] == config)
            #expect(store.activeDepositConfig(for: "acct_fd") == nil)
            #expect(store.activeDepositConfigs.isEmpty)
        }
    }

    /// A matured deposit is still worth showing — it has a final value — so
    /// maturity must not remove it the way closing the account does.
    @Test func aMaturedDepositStaysActiveUntilItsAccountCloses() async throws {
        try await withStore { store, _ in
            store.accounts = [
                Account(id: "acct_fd", name: "FD", type: .savings, offBudget: true, closed: false, sortOrder: 0, balance: 14_147_782),
            ]
            var matured = config
            matured.termMonths = 1
            await store.setDeposit(accountId: "acct_fd", config: matured)

            #expect(matured.hasMatured(on: DayDate(year: 2030, month: 1, day: 1)))
            #expect(store.activeDepositConfig(for: "acct_fd") == matured)
        }
    }
}
