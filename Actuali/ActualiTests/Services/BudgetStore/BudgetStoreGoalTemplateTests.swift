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

    // MARK: - The synced feature flags

    /// A store whose sync client was never configured, so every preference
    /// write throws before it reaches a database. The schema is complete so
    /// the recovery refresh in the failure path runs to its publish batch.
    /// Clean up `url`.
    private func makeStoreWhoseWritesFail() async throws -> (BudgetStore, URL) {
        let (database, url) = try await makeTestDatabase(
            TestSchema.core + [TestSchema.preferences, TestSchema.tags]
        )
        let store = BudgetStore.previewInstance()
        store.widgetSnapshotStore = nil
        store.configureForTesting(
            database: database,
            syncClient: SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        )
        return (store, url)
    }

    /// The Settings switch follows the tap, not the CRDT write: the flag is
    /// published first, and one toggle sends one notification.
    @Test func enablingGoalTemplatesPublishesTheFlagAndWritesThePreference() async throws {
        let (database, url) = try await makeTestDatabase(
            TestSchema.preferences, TestSchema.messagesCrdt, TestSchema.messagesClock
        )
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        #expect(!store.goalTemplatesEnabled)
        var published: [Bool] = []
        let subscription = store.$goalTemplatesEnabled.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        await store.setGoalTemplatesEnabled(true)

        // The optimistic flip only: one toggle, one notification.
        #expect(published == [true])
        #expect(store.goalTemplatesEnabled)
        let stored = try await DatabaseQueue(path: url.path).read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM preferences WHERE id = 'flags.goalTemplatesEnabled'"
            )
        }
        #expect(stored == "true")
    }

    /// A flag the budget gained behind the store's back — a sync pull writes
    /// the row — still reaches the switch. The refresh guard may only skip a
    /// row that a local toggle is about to replace.
    @Test func aRefreshPublishesAFlagChangedBehindTheStore() async throws {
        let (database, url) = try await makeTestDatabase(
            TestSchema.core + [TestSchema.preferences, TestSchema.tags]
        )
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        store.widgetSnapshotStore = nil
        #expect(!store.goalTemplatesEnabled)
        try await DatabaseQueue(path: url.path).write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO preferences (id, value)
                VALUES ('flags.goalTemplatesEnabled', 'true')
                """
            )
        }

        // Any write that refreshes afterwards; creating a tag is the simplest.
        _ = try await store.createTag(name: "trip")

        #expect(store.goalTemplatesEnabled)
    }

    /// The refresh guard's truth table: a fetched row may only be published
    /// when no write owned the flag during the reads and the user did not flip
    /// it meanwhile.
    @Test func aRefreshPublishesAFlagNoWriteTouched() {
        #expect(BudgetStore.flagSnapshotIsCurrent(
            writesAtCapture: 0, writesNow: 0, published: false, atCapture: false
        ))
        #expect(!BudgetStore.flagSnapshotIsCurrent(
            writesAtCapture: 1, writesNow: 0, published: false, atCapture: false
        ))
        #expect(!BudgetStore.flagSnapshotIsCurrent(
            writesAtCapture: 0, writesNow: 1, published: false, atCapture: false
        ))
        #expect(!BudgetStore.flagSnapshotIsCurrent(
            writesAtCapture: 0, writesNow: 0, published: true, atCapture: false
        ))
    }

    /// A write that committed the row and then failed — saving the sync clock
    /// is what usually throws — leaves the switch on what the budget stored,
    /// not on the rollback. The recovery re-read owns the final value.
    @Test func aFailedWriteThatCommittedTheRowEndsOnTheStoredFlag() async throws {
        let (store, url) = try await makeStoreWhoseWritesFail()
        defer { cleanup(url) }
        try await DatabaseQueue(path: url.path).write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO preferences (id, value)
                VALUES ('flags.goalTemplatesEnabled', 'true')
                """
            )
        }

        await store.setGoalTemplatesEnabled(true)

        #expect(store.goalTemplatesEnabled)
        #expect(store.error?.hasPrefix("Failed to update goal templates setting:") == true)
    }

    /// A failed write must not leave the switch on a flag the budget never
    /// stored. The published values pin the order the switch sees: on from the
    /// tap, then back off — not merely off at the end, which the old
    /// publish-after-the-write code produced too.
    @Test func failedGoalTemplateWriteShowsTheFlagOnThenRollsItBack() async throws {
        let (store, url) = try await makeStoreWhoseWritesFail()
        defer { cleanup(url) }
        var published: [Bool] = []
        let subscription = store.$goalTemplatesEnabled.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        await store.setGoalTemplatesEnabled(true)

        #expect(published == [true, false])
        #expect(!store.goalTemplatesEnabled)
        #expect(store.error?.hasPrefix("Failed to update goal templates setting:") == true)
    }

    /// The Automations Editor switch underneath it behaves the same way.
    @Test func failedAutomationsWriteShowsTheFlagOnThenRollsItBack() async throws {
        let (store, url) = try await makeStoreWhoseWritesFail()
        defer { cleanup(url) }
        var published: [Bool] = []
        let subscription = store.$goalTemplatesUIEnabled.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        await store.setGoalTemplatesUIEnabled(true)

        #expect(published == [true, false])
        #expect(!store.goalTemplatesUIEnabled)
        #expect(store.error?.hasPrefix("Failed to update automations setting:") == true)
    }
}
