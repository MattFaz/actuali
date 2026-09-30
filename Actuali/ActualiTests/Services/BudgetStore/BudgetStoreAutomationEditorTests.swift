import Foundation
import GRDB
import Testing
@testable import Actuali

/// The automations editor load path resolves names to ids; duplicate names
/// (legal — categories and pools are keyed by id) must resolve to the first
/// match rather than trapping in Dictionary(uniqueKeysWithValues:).
@MainActor
struct BudgetStoreAutomationEditorTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(
            TestSchema.transactions, TestSchema.accounts, TestSchema.categoryMapping,
            TestSchema.zeroBudgets, TestSchema.categories, TestSchema.categoryGroups,
            TestSchema.notes, TestSchema.messagesCrdt,
            """
            CREATE TABLE cleanup_groups (id TEXT PRIMARY KEY, name TEXT, tombstone INTEGER DEFAULT 0);

            INSERT INTO category_groups (id, name) VALUES ('grp-1', 'Daily');
            INSERT INTO category_groups (id, name, is_income) VALUES ('grp-inc', 'Income', 1);
            INSERT INTO categories (id, name, cat_group) VALUES ('cat-x', 'Spending', 'grp-1');
            INSERT INTO categories (id, name, cat_group, is_income) VALUES
                ('cat-salary-1', 'Salary', 'grp-inc', 1),
                ('cat-salary-2', 'Salary', 'grp-inc', 1);
            INSERT INTO category_mapping (id, transferId) VALUES
                ('cat-x', 'cat-x'),
                ('cat-salary-1', 'cat-salary-1'),
                ('cat-salary-2', 'cat-salary-2');
            INSERT INTO accounts (id, name, offbudget, sort_order) VALUES
                ('acct-1', 'Checking', 0, 1.0);
            INSERT INTO cleanup_groups (id, name) VALUES
                ('pool-1', 'Vacation'),
                ('pool-2', 'vacation');
            INSERT INTO cleanup_groups (id, name, tombstone) VALUES
                ('pool-3', 'Archived', 1);
            INSERT INTO notes (id, note) VALUES
                ('cat-x', '#template 10% of Salary'
                    || char(10) || '#cleanup Vacation sink'
                    || char(10) || '#cleanup New Pool source'
                    || char(10) || '#cleanup Archived sink');
            """
        )
    }

    @Test func loadResolvesNamesWithoutWritingCleanupGroups() async throws {
        let (database, url) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try await makeTestStore(database: database)

        let data = try await store.loadAutomationEditor(categoryId: "cat-x", month: "2024-01")

        #expect(data.incomeSources.count == 2)
        #expect(data.entries.count == 1)
        let resolved = data.entries.first?.template.category
        #expect(resolved == "cat-salary-1" || resolved == "cat-salary-2")
        // cleanup_groups is fetched ORDER BY name (BINARY), so 'Vacation'
        // deterministically precedes 'vacation'.
        let configuredIds = Set(data.cleanup.groups.map(\.groupId))
        #expect(configuredIds.contains("pool-1"))
        #expect(!configuredIds.contains("pool-2"))
        #expect(configuredIds.contains("pool-3"))
        #expect(data.cleanupGroups.contains { $0.name == "New Pool" })

        let liveGroups = try await database.fetchCleanupGroups()
        #expect(!liveGroups.contains { $0.name == "New Pool" })
        #expect(!liveGroups.contains { $0.id == "pool-3" })
    }

    @Test func saveCreatesAndRevivesCleanupGroups() async throws {
        let (database, url) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try await makeTestStore(database: database)
        let data = try await store.loadAutomationEditor(categoryId: "cat-x", month: "2024-01")

        try await store.saveAutomations(
            categoryId: "cat-x",
            templates: data.entries.map(\.template),
            cleanup: data.cleanup.toCleanupTemplates(),
            cleanupGroups: data.cleanupGroups
        )

        let liveGroups = try await database.fetchCleanupGroups()
        #expect(liveGroups.contains { $0.name == "New Pool" })
        #expect(liveGroups.contains { $0.id == "pool-3" })
    }
}
