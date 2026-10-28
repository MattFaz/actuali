import Foundation
import GRDB
import Testing
@testable import Actuali

struct SyncClientCategoryDeletionTests {
    private func makeDatabase(seed: String) async throws -> (BudgetDatabase, URL, SyncClient) {
        let (database, path) = try await makeTestDatabase(
            TestSchema.categories,
            TestSchema.categoryGroups,
            TestSchema.categoryMapping,
            TestSchema.transactions,
            TestSchema.zeroBudgets,
            TestSchema.messagesCrdt,
            seed
        )
        let syncClient = try await makeTestSyncClient(database: database)
        return (database, path, syncClient)
    }

    private func amount(_ categoryId: String, database: BudgetDatabase) async throws -> Int? {
        try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT amount FROM zero_budgets WHERE month = 202601 AND category = ?",
                arguments: [categoryId]
            )
        }
    }

    private func transferTarget(_ mappingId: String, database: BudgetDatabase) async throws -> String? {
        try await database.dbQueueForTesting.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT transferId FROM category_mapping WHERE id = ?",
                arguments: [mappingId]
            )
        }
    }

    @Test func deletingCategoryTransfersBudgetAndRedirectsTransactionHistory() async throws {
        let (database, path, syncClient) = try await makeDatabase(
            seed: """
            INSERT INTO category_groups (id, name, sort_order) VALUES
                ('grp-daily', 'Daily', 16384),
                ('grp-bills', 'Bills', 32768);
            INSERT INTO categories (id, name, cat_group, sort_order) VALUES
                ('cat-food', 'Food', 'grp-daily', 16384),
                ('cat-fun', 'Fun', 'grp-bills', 16384);
            INSERT INTO category_mapping (id, transferId) VALUES
                ('cat-food', 'cat-food'),
                ('cat-fun', 'cat-fun'),
                ('legacy-food', 'cat-food');
            INSERT INTO transactions (id, category, tombstone) VALUES ('txn-food', 'legacy-food', 0);
            INSERT INTO zero_budgets (id, month, category, amount) VALUES
                ('202601-cat-food', 202601, 'cat-food', 4500),
                ('202601-legacy-food', 202601, 'legacy-food', 2500),
                ('202601-cat-fun', 202601, 'cat-fun', 1500);
            """
        )

        defer { cleanup(path) }

        try await syncClient.deleteCategory(id: "cat-food", transferToId: "cat-fun")

        #expect(try await amount("cat-food", database: database) == 0)
        #expect(try await amount("legacy-food", database: database) == 0)
        #expect(try await amount("cat-fun", database: database) == 8500)
        #expect(try await transferTarget("cat-food", database: database) == "cat-fun")
        #expect(try await transferTarget("legacy-food", database: database) == "cat-fun")

        let transactionCategory = try await database.dbQueueForTesting.read { db in
            try String.fetchOne(db, sql: "SELECT category FROM transactions WHERE id = 'txn-food'")
        }
        let sourceTombstone = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT tombstone FROM categories WHERE id = 'cat-food'")
        }
        #expect(transactionCategory == "legacy-food")
        #expect(try await transferTarget("legacy-food", database: database) == "cat-fun")
        #expect(sourceTombstone == 1)

        let messages = try messageRows(path: path)
        #expect(messages.contains { $0["dataset"] as String? == "categories" && $0["row"] as String? == "cat-food" && $0["column"] as String? == "tombstone" })
        #expect(messages.contains { $0["dataset"] as String? == "category_mapping" && $0["row"] as String? == "legacy-food" && $0["column"] as String? == "transferId" })
    }

    @Test func deletionWithoutDestinationRefusesToDiscardTransactionHistory() async throws {
        let (database, path, syncClient) = try await makeDatabase(
            seed: """
            INSERT INTO category_groups (id, name, sort_order) VALUES ('grp-daily', 'Daily', 16384);
            INSERT INTO categories (id, name, cat_group, sort_order) VALUES ('cat-food', 'Food', 'grp-daily', 16384);
            INSERT INTO category_mapping (id, transferId) VALUES ('cat-food', 'cat-food');
            INSERT INTO transactions (id, category, tombstone) VALUES ('txn-food', 'cat-food', 0);
            """
        )

        defer { cleanup(path) }

        await #expect(throws: BudgetStoreError.missingTransferDestination) {
            try await syncClient.deleteCategory(id: "cat-food", transferToId: nil)
        }

        #expect(try messageRows(path: path).isEmpty)
        let categoryTombstone = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT tombstone FROM categories WHERE id = 'cat-food'")
        }
        #expect(categoryTombstone == 0)
    }

    @Test func deletingGroupTransfersAllCategoryBudgetsAndTombstonesTheGroup() async throws {
        let (database, path, syncClient) = try await makeDatabase(
            seed: """
            INSERT INTO category_groups (id, name, sort_order) VALUES
                ('grp-source', 'Old group', 16384),
                ('grp-target', 'New group', 32768);
            INSERT INTO categories (id, name, cat_group, sort_order) VALUES
                ('cat-one', 'One', 'grp-source', 16384),
                ('cat-two', 'Two', 'grp-source', 32768),
                ('cat-target', 'Target', 'grp-target', 16384);
            INSERT INTO category_mapping (id, transferId) VALUES
                ('cat-one', 'cat-one'),
                ('cat-two', 'cat-two'),
                ('cat-target', 'cat-target');
            INSERT INTO zero_budgets (id, month, category, amount) VALUES
                ('202601-cat-one', 202601, 'cat-one', 2000),
                ('202601-cat-two', 202601, 'cat-two', 500),
                ('202601-cat-target', 202601, 'cat-target', 1000);
            """
        )

        defer { cleanup(path) }

        try await syncClient.deleteCategoryGroup(id: "grp-source", transferToId: "cat-target")

        #expect(try await amount("cat-one", database: database) == 0)
        #expect(try await amount("cat-two", database: database) == 0)
        #expect(try await amount("cat-target", database: database) == 3500)
        #expect(try await transferTarget("cat-one", database: database) == "cat-target")
        #expect(try await transferTarget("cat-two", database: database) == "cat-target")

        let groupTombstone = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT tombstone FROM category_groups WHERE id = 'grp-source'")
        }
        #expect(groupTombstone == 1)
    }
}
