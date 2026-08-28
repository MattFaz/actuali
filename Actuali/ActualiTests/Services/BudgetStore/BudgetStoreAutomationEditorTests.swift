import Foundation
import GRDB
import Testing
@testable import Actuali

/// The automations editor load path resolves names to ids; duplicate names
/// (legal — categories and pools are keyed by id) must resolve to the first
/// match rather than trapping in Dictionary(uniqueKeysWithValues:).
@MainActor
struct BudgetStoreAutomationEditorTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    acct TEXT,
                    category TEXT,
                    description TEXT,
                    amount INTEGER,
                    date INTEGER,
                    parent_id TEXT,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0
                );
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    offbudget INTEGER DEFAULT 0,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0
                );
                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
                );
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
                CREATE TABLE category_groups (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    is_income INTEGER DEFAULT 0,
                    sort_order REAL,
                    hidden INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                );
                CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
                CREATE TABLE cleanup_groups (
                    id TEXT PRIMARY KEY,
                    name TEXT,
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
                INSERT INTO notes (id, note) VALUES
                    ('cat-x', '#template 10% of Salary' || char(10) || '#cleanup Vacation sink');
            """)
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func makeStore(database: BudgetDatabase) async throws -> BudgetStore {
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)
        return store
    }

    @Test func duplicateNamesResolveToFirstMatch() async throws {
        let (database, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try await makeStore(database: database)

        let data = try await store.loadAutomationEditor(categoryId: "cat-x", month: "2024-01")

        #expect(data.incomeSources.count == 2)
        #expect(data.entries.count == 1)
        let resolved = data.entries.first?.template.category
        #expect(resolved == "cat-salary-1" || resolved == "cat-salary-2")
        // cleanup_groups is fetched ORDER BY name (BINARY), so 'Vacation'
        // deterministically precedes 'vacation'.
        #expect(data.cleanup.groups.map(\.groupId) == ["pool-1"])
    }
}
