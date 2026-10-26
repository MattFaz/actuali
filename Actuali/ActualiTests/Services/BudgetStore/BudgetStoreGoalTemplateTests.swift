import Combine
import Foundation
import GRDB
import Testing
@testable import Actuali

/// `runGoalTemplates` scoped to one category (the Budget tab's per-category
/// "Apply Budget Template" action, GH #495) or to one group's categories (the
/// group header's long-press actions).
@MainActor
struct BudgetStoreGoalTemplateTests {
    /// Three categories in two groups with `#template` notes in their own budget file, opened
    /// the same way the loan-payment tests do.
    private func makeStore() async throws -> (BudgetStore, URL) {
        let (store, manager, root) = makeFileBackedStore()
        let budgetId = "budget-\(UUID().uuidString)"
        try seedBudget(id: budgetId, in: manager, sql: TestSchema.upstream + """

        INSERT INTO category_groups (id, name) VALUES ('grp_1', 'Bills'), ('grp_2', 'Fun');
        INSERT INTO categories (id, name, cat_group) VALUES
            ('cat_a', 'Rent', 'grp_1'),
            ('cat_b', 'Power', 'grp_1'),
            ('cat_c', 'Games', 'grp_2');
        INSERT INTO category_mapping (id, transferId) VALUES
            ('cat_a', 'cat_a'),
            ('cat_b', 'cat_b'),
            ('cat_c', 'cat_c');
        CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, note TEXT);
        INSERT INTO notes (id, note) VALUES
            ('cat_a', '#template 10'),
            ('cat_b', '#template 20'),
            ('cat_c', '#template 30');
        """)
        await store.loadLocalBudget(budgetId)
        store.currentBudgetId = budgetId
        return (store, root)
    }

    @Test func singleCategoryApplyChangesOnlyThatCategory() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(await store.runGoalTemplates(
            month: "2026-09", action: .apply, categoryId: "cat_a"
        ) == .applied(1))

        // `#template 10` budgets $10.00; the sibling stays at zero — the run
        // must not leak past the category it was scoped to.
        let month = try #require(store.currentBudgetMonth)
        let budgeted = Dictionary(
            uniqueKeysWithValues: month.allCategoryBudgets.map { ($0.categoryId, $0.budgeted) }
        )
        #expect(budgeted["cat_a"] == 1000)
        #expect(budgeted["cat_b"] == 0)
    }

    @Test func groupApplyChangesOnlyThatGroupsCategories() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(await store.runGoalTemplates(
            month: "2026-09", action: .apply, categoryIds: ["cat_a", "cat_b"]
        ) == .applied(2))

        // Both of the group's categories are budgeted; the category in the
        // other group stays at zero.
        let month = try #require(store.currentBudgetMonth)
        let budgeted = Dictionary(
            uniqueKeysWithValues: month.allCategoryBudgets.map { ($0.categoryId, $0.budgeted) }
        )
        #expect(budgeted["cat_a"] == 1000)
        #expect(budgeted["cat_b"] == 2000)
        #expect(budgeted["cat_c"] == 0)
    }

    // MARK: - The synced feature flag

    /// The Settings switch follows the tap, not the CRDT write: the flag is
    /// published first and only rolled back if the write fails.
    @Test func enablingGoalTemplatesPublishesTheFlagAndWritesThePreference() async throws {
        let (database, url) = try await makeTestDatabase(
            TestSchema.preferences, TestSchema.messagesCrdt, TestSchema.messagesClock
        )
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        #expect(!store.goalTemplatesEnabled)

        await store.setGoalTemplatesEnabled(true)

        #expect(store.goalTemplatesEnabled)
        let stored = try await DatabaseQueue(path: url.path).read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM preferences WHERE id = 'flags.goalTemplatesEnabled'"
            )
        }
        #expect(stored == "true")
    }

    /// A failed write must not leave the switch on a flag the budget never
    /// stored. The published values pin the order the switch sees: on from the
    /// tap, then back off — not merely off at the end, which the old
    /// publish-after-the-write code produced too.
    @Test func failedGoalTemplateWriteShowsTheFlagOnThenRollsItBack() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.preferences)
        defer { cleanup(url) }
        let store = BudgetStore.previewInstance()
        // Left unconfigured, so `setPreference` throws before it reaches a DB.
        store.configureForTesting(
            database: database,
            syncClient: SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        )
        var published: [Bool] = []
        let subscription = store.$goalTemplatesEnabled.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        await store.setGoalTemplatesEnabled(true)

        #expect(published == [true, false])
        #expect(!store.goalTemplatesEnabled)
        #expect(store.error != nil)
    }
}
