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
        let (store, manager, root) = makeFileBackedStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let budgetId = "budget-\(UUID().uuidString)"

        try seedBudget(id: budgetId, in: manager)
        try await seedLoan(config, accountId: "acct_car", budgetId: budgetId, in: manager)

        await store.loadLocalBudget(budgetId)

        #expect(store.loanConfigs["acct_car"] == config)
    }

    @Test func loansAreScopedPerBudgetOnLoad() async throws {
        let (store, manager, root) = makeFileBackedStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let budgetA = "budget-\(UUID().uuidString)"
        let budgetB = "budget-\(UUID().uuidString)"

        try seedBudget(id: budgetA, in: manager)
        try seedBudget(id: budgetB, in: manager)
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
        let (database, url) = try await makeTestDatabase(TestSchema.preferences, TestSchema.messagesCrdt)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
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
