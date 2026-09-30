import Foundation
import GRDB
import Testing
@testable import Actuali

struct SyncClientGoalTemplateWritesTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(
            TestSchema.zeroBudgets, TestSchema.categories, TestSchema.messagesCrdt,
            "INSERT INTO categories (id, name) VALUES ('cat-1', 'Groceries')"
        )
    }

    /// Synchronous, so the read doesn't pick GRDB's async overload inside
    /// async test bodies.
    private func firstRow(path: URL, sql: String) throws -> Row? {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in try Row.fetchOne(db, sql: sql) }
    }

    @Test func budgetAndGoalMergeIntoOneRowWrite() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeTestSyncClient(database: database)

        try await syncClient.applyGoalTemplateWrites(
            month: "2024-01",
            budgets: [.init(category: "cat-1", amount: 40000)],
            goals: [.init(category: "cat-1", goal: 50000, longGoal: true)]
        )

        let row = try #require(try firstRow(path: path, sql: "SELECT * FROM zero_budgets"))
        #expect(row["id"] == "202401-cat-1")
        #expect(row["amount"] == 40000)
        #expect(row["goal"] == 50000)
        #expect(row["long_goal"] == 1)

        // One row created once: month, category, amount, goal, long_goal.
        let messages = try messageRows(path: path)
        #expect(messages.count == 5)
        #expect(messages.allSatisfy { ($0["row"] as String?) == "202401-cat-1" })
        let byColumn = Dictionary(uniqueKeysWithValues: messages.map {
            ($0["column"] as String? ?? "", $0["value"] as String? ?? "")
        })
        #expect(byColumn["goal"] == "N:50000")
        #expect(byColumn["long_goal"] == "N:1")
        #expect(byColumn["amount"] == "N:40000")
    }

    @Test func orphanGoalResetWritesNulls() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
            INSERT INTO zero_budgets (id, month, category, amount, goal, long_goal)
            VALUES ('202401-cat-1', 202401, 'cat-1', 0, 5000, 1)
            """)
        }
        let syncClient = try await makeTestSyncClient(database: database)

        try await syncClient.applyGoalTemplateWrites(
            month: "2024-01",
            budgets: [],
            goals: [.init(category: "cat-1", goal: nil, longGoal: false)]
        )

        let row = try #require(try firstRow(path: path, sql: "SELECT * FROM zero_budgets"))
        #expect((row["goal"] as Int?) == nil)
        #expect((row["long_goal"] as Int?) == nil)
    }

    @Test func storeGoalDefsWritesDefinitionAndSource() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeTestSyncClient(database: database)

        let goalDef = #"[{"type":"simple","directive":"template","priority":0,"monthly":50}]"#
        try await syncClient.storeGoalDefs([("cat-1", goalDef, "notes")])

        let row = try #require(try firstRow(
            path: path,
            sql: "SELECT goal_def, template_settings FROM categories WHERE id = 'cat-1'"
        ))
        #expect((row["goal_def"] as String?) == goalDef)
        #expect((row["template_settings"] as String?) == #"{"source": "notes"}"#)

        let datasets = try Set(messageRows(path: path).compactMap { $0["dataset"] as String? })
        #expect(datasets == ["categories"])
    }

    @Test func cleanupWritesDefinitionAndResetsLongGoal() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeTestSyncClient(database: database)
        let cleanupDef = #"[{"groupId":null,"role":"source"}]"#
        let templateSettingsBefore: String? = try firstRow(
            path: path,
            sql: "SELECT template_settings FROM categories WHERE id = 'cat-1'"
        )?["template_settings"]

        try await syncClient.storeCleanupDefs([("cat-1", cleanupDef)])
        try await syncClient.applyGoalTemplateWrites(
            month: "2024-01",
            budgets: [.init(category: "cat-1", amount: 4000)],
            goals: [.init(category: "cat-1", goal: 4000, longGoal: false)],
            writeFalseLongGoalsAsZero: true
        )

        let category = try #require(try firstRow(
            path: path,
            sql: "SELECT cleanup_def, template_settings FROM categories WHERE id = 'cat-1'"
        ))
        #expect((category["cleanup_def"] as String?) == cleanupDef)
        #expect((category["template_settings"] as String?) == templateSettingsBefore)
        let budget = try #require(try firstRow(path: path, sql: "SELECT * FROM zero_budgets"))
        #expect(budget["long_goal"] == 0)
    }
}
