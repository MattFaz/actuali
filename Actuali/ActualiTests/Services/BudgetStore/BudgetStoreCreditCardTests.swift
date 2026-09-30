import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreCreditCardTests {
    private func makeStore() -> (BudgetStore, BudgetFileManager, String, URL) {
        let (store, manager, root) = makeFileBackedStore()
        return (store, manager, "budget-\(UUID().uuidString)", root)
    }

    @Test func legacyDefaultsMigrateOnLoad() async throws {
        let (store, manager, budgetId, root) = makeStore()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removeObject(forKey: "creditCardStatementDays_\(budgetId)")
            UserDefaults.standard.removeObject(forKey: "creditCardDueOffsets_\(budgetId)")
            UserDefaults.standard.removeObject(forKey: "creditCardLimits_\(budgetId)")
        }

        try seedBudget(id: budgetId, in: manager)

        // Seed legacy UserDefaults keys
        UserDefaults.standard.set(["acct_chase": 18], forKey: "creditCardStatementDays_\(budgetId)")
        UserDefaults.standard.set(["acct_chase": 25], forKey: "creditCardDueOffsets_\(budgetId)")
        UserDefaults.standard.set(["acct_chase": 500_000], forKey: "creditCardLimits_\(budgetId)")

        await store.loadLocalBudget(budgetId)

        #expect(store.creditCardStatementDays["acct_chase"] == 18)
        #expect(store.creditCardDueOffsets["acct_chase"] == 25)
        #expect(store.creditCardLimits["acct_chase"] == 500_000)

        // Legacy UserDefaults keys must be erased so removed cards don't resurrect
        #expect(UserDefaults.standard.dictionary(forKey: "creditCardStatementDays_\(budgetId)") == nil)
        #expect(UserDefaults.standard.dictionary(forKey: "creditCardDueOffsets_\(budgetId)") == nil)
        #expect(UserDefaults.standard.dictionary(forKey: "creditCardLimits_\(budgetId)") == nil)
    }

    @Test func budgetStoreReflectsSyncedCardsFromDatabase() async throws {
        let (store, manager, budgetId, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try seedBudget(id: budgetId, in: manager)

        // Insert directly into preferences table
        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: budgetId).path)
        let config = CreditCardConfig(statementDay: 20, dueOffsetDays: 30, limit: 1_000_000)
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
        #expect(store.creditCardLimits["acct_apple"] == 1_000_000)
    }

    @Test func cardsAreScopedPerBudgetOnLoad() async throws {
        let (store, manager, budgetA, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let budgetB = "budget-\(UUID().uuidString)"

        try seedBudget(id: budgetA, in: manager)
        try seedBudget(id: budgetB, in: manager)

        let dbQueueA = try DatabaseQueue(path: manager.databasePath(for: budgetA).path)
        let configA = CreditCardConfig(statementDay: 18, dueOffsetDays: 25, limit: 500_000)
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
        let (database, url) = try await makeTestDatabase(TestSchema.preferences, TestSchema.messagesCrdt)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        store.currentBudgetId = "test-budget"

        await store.setCreditCard(accountId: "acct_chase", statementDay: 18, paymentDue: .daysAfter(25), limit: 500_000)

        #expect(store.creditCardStatementDays["acct_chase"] == 18)
        #expect(store.creditCardDueOffsets["acct_chase"] == 25)
        #expect(store.creditCardLimits["acct_chase"] == 500_000)

        let configs = try await database.fetchCreditCardConfigs()
        #expect(configs["acct_chase"]?.statementDay == 18)
        #expect(configs["acct_chase"]?.dueOffsetDays == 25)
        #expect(configs["acct_chase"]?.limit == 500_000)
    }
}
