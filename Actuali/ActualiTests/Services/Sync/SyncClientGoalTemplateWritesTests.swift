import Foundation
import GRDB
import Testing
@testable import Actuali

struct SyncClientGoalTemplateWritesTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE zero_budgets (
                    id TEXT PRIMARY KEY,
                    month INTEGER,
                    category TEXT,
                    amount INTEGER DEFAULT 0,
                    carryover INTEGER DEFAULT 0
                );
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    is_income INTEGER DEFAULT 0,
                    cat_group TEXT,
                    sort_order REAL,
                    hidden INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                );
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                );
                INSERT INTO categories (id, name) VALUES ('cat-1', 'Groceries');
                """)
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func makeSyncClient(database: BudgetDatabase) async throws -> SyncClient {
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        return syncClient
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // Synchronous helpers, so the reads don't pick GRDB's async overloads
    // inside async test bodies.
    private func firstRow(path: URL, sql: String) throws -> Row? {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in try Row.fetchOne(db, sql: sql) }
    }

    private func messageRows(path: URL) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messages_crdt ORDER BY timestamp")
        }
    }

    @Test func budgetAndGoalMergeIntoOneRowWrite() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.applyGoalTemplateWrites(
            month: "2024-01",
            budgets: [.init(category: "cat-1", amount: 40000)],
            goals: [.init(category: "cat-1", goal: 50000, longGoal: true)])

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
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO zero_budgets (id, month, category, amount, goal, long_goal)
                VALUES ('202401-cat-1', 202401, 'cat-1', 0, 5000, 1)
                """)
        }
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.applyGoalTemplateWrites(
            month: "2024-01",
            budgets: [],
            goals: [.init(category: "cat-1", goal: nil, longGoal: false)])

        let row = try #require(try firstRow(path: path, sql: "SELECT * FROM zero_budgets"))
        #expect((row["goal"] as Int?) == nil)
        #expect((row["long_goal"] as Int?) == nil)
    }

    @Test func storeGoalDefsWritesDefinitionAndSource() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        let goalDef = #"[{"type":"simple","directive":"template","priority":0,"monthly":50}]"#
        try await syncClient.storeGoalDefs([("cat-1", goalDef, "notes")])

        let row = try #require(try firstRow(
            path: path,
            sql: "SELECT goal_def, template_settings FROM categories WHERE id = 'cat-1'"))
        #expect((row["goal_def"] as String?) == goalDef)
        #expect((row["template_settings"] as String?) == #"{"source": "notes"}"#)

        let datasets = Set(try messageRows(path: path).compactMap { $0["dataset"] as String? })
        #expect(datasets == ["categories"])
    }
}
