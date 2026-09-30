import Foundation
import GRDB
import Testing
@testable import Actuali

/// `runGoalTemplates` scoped to one category — the Budget tab's per-category
/// "Apply Budget Template" action (GH #495).
@MainActor
struct BudgetStoreGoalTemplateTests {
    /// Two categories with `#template` notes in their own budget file, opened
    /// the same way the loan-payment tests do.
    private func makeStore() async throws -> (BudgetStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goal-template-\(UUID().uuidString)", isDirectory: true)
        let manager = BudgetFileManager(rootDirectoryForTesting: root)
        let budgetId = "budget-\(UUID().uuidString)"

        let dir = manager.budgetDirectory(for: budgetId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: budgetId).path)
        try await dbQueue.write { db in
            try db.execute(sql: BudgetStoreInitialSyncTests.upstreamSchema)
            try db.execute(sql: """
            INSERT INTO category_groups (id, name) VALUES ('grp_1', 'Bills');
            INSERT INTO categories (id, name, cat_group) VALUES
                ('cat_a', 'Rent', 'grp_1'),
                ('cat_b', 'Power', 'grp_1');
            INSERT INTO category_mapping (id, transferId) VALUES
                ('cat_a', 'cat_a'),
                ('cat_b', 'cat_b');
            CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes (id, note) VALUES
                ('cat_a', '#template 10'),
                ('cat_b', '#template 20');
            """)
        }
        try JSONEncoder().encode(BudgetMetadata(
            id: budgetId, budgetName: "Seed", cloudFileId: "cf-1", groupId: "group-1",
            resetClock: nil, lastUploaded: nil, encryptKeyId: nil
        )).write(to: manager.metadataPath(for: budgetId))

        let store = BudgetStore.previewInstance()
        store.setFileManagerForTesting(manager)
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
}
