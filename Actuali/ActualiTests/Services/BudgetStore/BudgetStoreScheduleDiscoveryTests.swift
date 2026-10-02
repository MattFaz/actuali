import GRDB
import Testing
@testable import Actuali

/// GH #543 item 13: schedule discovery end-to-end through `BudgetStore`.
/// The sweep is `@concurrent` so the CPU-bound match loop runs off the main
/// actor — under NONISOLATED_NONSENDING_BY_DEFAULT a plain `nonisolated async`
/// function would have inherited the caller's main actor. The attribute is
/// compiler-enforced, so these tests pin the behavior rather than the executor.
@MainActor
struct BudgetStoreScheduleDiscoveryTests {
    private func makeStore(_ database: BudgetDatabase) async throws -> BudgetStore {
        let store = BudgetStore.previewInstance()
        let syncClient = try await makeTestSyncClient(database: database)
        store.configureForTesting(database: database, syncClient: syncClient)
        store.accounts = [Account(
            id: "acct-1", name: "Checking", type: .checking,
            offBudget: false, closed: false, sortOrder: 0, balance: 0
        )]
        return store
    }

    private func insertMonthlyHistory(_ db: BudgetDatabase) throws {
        try db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
            INSERT INTO accounts (id, name, type) VALUES ('acct-1', 'Checking', 'checking')
            """)
            try conn.execute(sql: "INSERT INTO payees (id, name) VALUES ('payee-1', 'Rent')")
            try conn.execute(sql: "INSERT INTO payee_mapping (id, targetId) VALUES ('pm-1', 'payee-1')")
            // Three exact monthly repeats: the engine's minimum pattern.
            for (index, date) in [20_260_615, 20_260_715, 20_260_815].enumerated() {
                try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, description, date)
                VALUES (?, 'acct-1', -150000, 'pm-1', ?)
                """, arguments: ["tx-\(index)", date])
            }
        }
    }

    @Test func discoverSchedulesProposesMonthlyRepeat() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        try insertMonthlyHistory(database)
        let store = try await makeStore(database)

        let proposals = await store.discoverSchedules()
        let proposal = try #require(proposals.first)
        #expect(proposals.count == 1)
        #expect(proposal.accountId == "acct-1")
        #expect(proposal.payeeId == "payee-1")
        #expect(proposal.amount == -150_000)
    }

    @Test func discoverSchedulesWithNoHistoryReturnsEmpty() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeStore(database)

        #expect(await store.discoverSchedules().isEmpty)
    }
}
