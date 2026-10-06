import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreBudgetTypeTests {
    private func makeStore() async throws -> (BudgetStore, BudgetDatabase, URL, String, String) {
        let (database, path) = try await makeTestDatabase(
            TestSchema.upstream,
            TestSchema.reflectBudgets,
            TestSchema.zeroBudgetMonths,
            TestSchema.schedules,
            TestSchema.schedulesNextDate
        )
        let components = Calendar.current.dateComponents([.year, .month], from: Date())
        let year = try #require(components.year)
        let monthNumber = try #require(components.month)
        let month = String(format: "%04d-%02d", year, monthNumber)
        let monthInt = year * 100 + monthNumber
        try await DatabaseQueue(path: path.path).write { db in
            try db.execute(
                sql: """
                INSERT INTO category_groups (id, name, is_income, sort_order)
                VALUES ('group-1', 'Test', 0, 1)
                """
            )
            try db.execute(
                sql: """
                INSERT INTO categories (id, name, is_income, cat_group, sort_order)
                VALUES ('category-1', 'Test category', 0, 'group-1', 1)
                """
            )
            try db.execute(
                sql: """
                INSERT INTO zero_budgets (id, month, category, amount)
                VALUES ('zero-1', ?, 'category-1', 100)
                """,
                arguments: [monthInt]
            )
            try db.execute(
                sql: """
                INSERT INTO reflect_budgets (id, month, category, amount)
                VALUES ('reflect-1', ?, 'category-1', 200)
                """,
                arguments: [monthInt]
            )
        }

        let store = try await makeTestStore(database: database)
        let budgetId = "budget-" + UUID().uuidString
        store.currentBudgetId = budgetId
        await store.fetchBudgetMonth(month)
        return (store, database, path, budgetId, month)
    }

    @Test func changingBudgetTypePersistsAndSwitchesBudgetTable() async throws {
        let (store, database, path, _, month) = try await makeStore()
        defer { cleanup(path) }

        await store.setBudgetType(.tracking)

        #expect(store.budgetType == .tracking)
        #expect(store.currentBudgetMonth?.isTrackingBudget == true)
        #expect(store.currentBudgetMonth?.categoryBudgets.first?.budgeted == 200)
        #expect(try await database.fetchPreference(id: "budgetType") == "tracking")

        let trackingMonth = try await database.fetchBudgetMonth(month: month)
        #expect(trackingMonth.isTrackingBudget)
        #expect(trackingMonth.categoryBudgets.first?.budgeted == 200)

        let firstMessages = try messageRows(path: path)
        #expect(firstMessages.count == 1)
        #expect(firstMessages.first?["dataset"] == "preferences")
        #expect(firstMessages.first?["row"] == "budgetType")
        #expect(firstMessages.first?["column"] == "value")
        #expect(firstMessages.first?["value"] == "S:tracking")

        await store.setBudgetType(.envelope)

        #expect(store.budgetType == .envelope)
        #expect(store.currentBudgetMonth?.isTrackingBudget == false)
        #expect(store.currentBudgetMonth?.categoryBudgets.first?.budgeted == 100)
        #expect(try await database.fetchPreference(id: "budgetType") == "envelope")

        let envelopeMonth = try await database.fetchBudgetMonth(month: month)
        #expect(!envelopeMonth.isTrackingBudget)
        #expect(envelopeMonth.categoryBudgets.first?.budgeted == 100)

        let messages = try messageRows(path: path)
        #expect(messages.count == 2)
        #expect(messages.last?["value"] == "S:envelope")
    }

    @Test func failedBudgetTypeChangeRestoresPreviousType() async throws {
        let (store, database, path, _, _) = try await makeStore()
        defer { cleanup(path) }

        try await DatabaseQueue(path: path.path).write { db in
            try db.execute(sql: "DROP TABLE messages_crdt")
        }

        await store.setBudgetType(.tracking)

        #expect(store.budgetType == .envelope)
        #expect(store.error != nil)
        #expect(try await database.fetchPreference(id: "budgetType") == nil)
    }

    @Test func clockSaveFailureKeepsCommittedBudgetType() async throws {
        let (store, database, path, _, month) = try await makeStore()
        defer { cleanup(path) }

        try await DatabaseQueue(path: path.path).write { db in
            try db.execute(sql: """
            CREATE TRIGGER fail_clock_save BEFORE INSERT ON messages_clock
            BEGIN SELECT RAISE(FAIL, 'test clock save failure'); END;
            """)
        }

        await store.setBudgetType(.tracking)

        #expect(try await database.fetchPreference(id: "budgetType") == "tracking")
        #expect(try messageRows(path: path).count == 1)
        #expect(store.budgetType == .tracking)
        #expect(store.currentBudgetMonth?.isTrackingBudget == true)
        #expect(store.error?.contains("test clock save failure") == true)
        #expect(try await database.fetchBudgetMonth(month: month).isTrackingBudget)
    }

    @Test func failedChangeDoesNotPublishErrorOverAnotherBudget() async throws {
        let (store, _, path, _, _) = try await makeStore()
        defer { cleanup(path) }
        try await DatabaseQueue(path: path.path).write { db in
            try db.execute(sql: "DROP TABLE messages_crdt")
        }

        let refreshing = Gate()
        let resume = Gate()
        store.bankSyncAccountsFetchedForTesting = {
            refreshing.open()
            await resume.wait()
        }
        let change = Task { await store.setBudgetType(.tracking) }
        await refreshing.wait()

        store.closeDatabaseForTesting()
        store.currentBudgetId = "budget-" + UUID().uuidString
        store.error = "new budget error"
        resume.open()
        await change.value

        #expect(store.budgetType == .envelope)
        #expect(store.error == "new budget error")
    }

    @Test(arguments: ["tracking", "report"])
    func openingTrackingBudgetPublishesTrackingType(preference: String) async throws {
        let (store, manager, root) = makeFileBackedStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let budgetId = "budget-" + UUID().uuidString
        try seedBudget(
            id: budgetId, in: manager,
            sql: TestSchema.upstream
                + "INSERT INTO preferences (id, value) VALUES ('budgetType', '\(preference)');"
        )

        store.currentBudgetId = budgetId
        await store.loadLocalBudget(budgetId)

        #expect(store.budgetType == .tracking)
    }

    @Test func refreshPublishesBudgetTypeChangedByAnotherClient() async throws {
        let (store, _, path, _, _) = try await makeStore()
        defer { cleanup(path) }

        try await DatabaseQueue(path: path.path).write { db in
            try db.execute(sql: """
            INSERT INTO preferences (id, value) VALUES ('budgetType', 'tracking')
            """)
        }
        await store.sync()

        #expect(store.budgetType == .tracking)
        #expect(store.currentBudgetMonth?.isTrackingBudget == true)
        #expect(store.currentBudgetMonth?.categoryBudgets.first?.budgeted == 200)
        #expect(try messageRows(path: path).isEmpty)
    }

    @Test func budgetTypeChangeRequiresConfiguredSync() async throws {
        let detachedStore = BudgetStore.previewInstance()
        detachedStore.currentBudgetId = "budget-" + UUID().uuidString
        detachedStore.isConnected = true
        #expect(!detachedStore.canChangeBudgetType)

        let (database, path) = try await makeTestDatabase(TestSchema.upstream)
        defer { cleanup(path) }
        let configuredStore = try await makeTestStore(database: database)
        configuredStore.currentBudgetId = "budget-" + UUID().uuidString
        configuredStore.isConnected = true

        #expect(configuredStore.canChangeBudgetType)
    }
}
