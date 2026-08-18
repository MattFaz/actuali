import Foundation
import GRDB
import Testing
@testable import Actuali

/// Category and group creation through the store (GH #284). The database
/// tests cover what lands in SQLite; this covers what goes out over CRDT —
/// the `category_mapping` self-reference and the sort_order updates the shove
/// pushes onto siblings, which is what upstream compatibility hangs on.
@MainActor
struct BudgetStoreCreateCategoryTests {

    /// The category tables plus the message log the sync layer writes to.
    /// `refreshDataOnly` fetches more than this after a write, but it swallows
    /// its own failures, same as in BudgetStoreCreateAccountTests.
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
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

                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
                );

                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                );

                INSERT INTO category_groups (id, name, sort_order)
                    VALUES ('grp-daily', 'Daily', 16384.0);
                INSERT INTO categories (id, name, cat_group, sort_order) VALUES
                    ('cat-groceries', 'Groceries', 'grp-daily', 16384.0),
                    ('cat-fuel', 'Fuel', 'grp-daily', 32768.0);
                INSERT INTO category_mapping (id, transferId) VALUES
                    ('cat-groceries', 'cat-groceries'),
                    ('cat-fuel', 'cat-fuel');
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

    private func rows(path: URL, sql: String) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: sql)
        }
    }

    private func count(path: URL, sql: String) throws -> Int {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Int.fetchOne(db, sql: sql) ?? 0
        }
    }

    /// The columns a dataset's messages covered, sorted so the assertion
    /// doesn't depend on `syncableFields`' dictionary order.
    private func messagedColumns(path: URL, dataset: String, row: String) throws -> [String] {
        try rows(
            path: path,
            sql: "SELECT column FROM messages_crdt WHERE dataset = '\(dataset)' AND row = '\(row)'"
        )
        .map { $0["column"] as String }
        .sorted()
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func creatingAGroupMessagesEverySyncedColumn() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        let group = try await store.createCategoryGroup(name: "  Fun Money  ")
        #expect(group.name == "Fun Money")

        #expect(try messagedColumns(path: url, dataset: "category_groups", row: group.id) == [
            "hidden", "is_income", "name", "sort_order", "tombstone"
        ])
    }

    @Test func creatingACategoryMessagesItsColumnsAndItsSelfMapping() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        let category = try await store.createCategory(name: "Coffee", groupId: "grp-daily")

        #expect(try messagedColumns(path: url, dataset: "categories", row: category.id) == [
            "cat_group", "hidden", "is_income", "name", "sort_order", "tombstone"
        ])

        // The self-mapping upstream pairs with every category, pointing at
        // itself — without it the transaction joins resolve to nothing.
        let mapping = try rows(
            path: url,
            sql: "SELECT column, value FROM messages_crdt WHERE dataset = 'category_mapping' AND row = '\(category.id)'")
        #expect(mapping.count == 1)
        #expect(mapping[0]["column"] == "transferId")
        #expect(mapping[0]["value"] == "S:\(category.id)")
    }

    /// The shove is the part another client can't reconstruct for itself: if
    /// the moved rows' new sort_orders never leave this device, the group
    /// comes out in a different order everywhere else.
    @Test func everyShovedSiblingGetsASortOrderMessageCarryingItsNewValue() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        // Close the gap at the top of the group so the insert has to shove.
        try database.dbQueueForTesting.write { db in
            try db.execute(sql: "UPDATE categories SET sort_order = 2.0 WHERE id = 'cat-groceries'")
        }

        let category = try await store.createCategory(name: "Coffee", groupId: "grp-daily")

        let moved = try rows(
            path: url,
            sql: """
                SELECT row, value FROM messages_crdt
                WHERE dataset = 'categories' AND column = 'sort_order' AND row != '\(category.id)'
                ORDER BY row
                """)
        #expect(moved.map { $0["row"] as String } == ["cat-fuel", "cat-groceries"])

        // Each message carries the value actually written to its row, so a
        // client applying them lands on the same order this device shows.
        for message in moved {
            let id: String = message["row"]
            let value: String = message["value"]
            let stored: Double = try rows(
                path: url,
                sql: "SELECT sort_order FROM categories WHERE id = '\(id)'")[0]["sort_order"]
            #expect(CRDTValue.deserialize(value) == stored.databaseValue)
        }
    }

    @Test func aCategoryThatFitsWithoutShovingMessagesNoSiblings() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        let category = try await store.createCategory(name: "Coffee", groupId: "grp-daily")

        #expect(try count(
            path: url,
            sql: """
                SELECT COUNT(*) FROM messages_crdt
                WHERE dataset = 'categories' AND column = 'sort_order' AND row != '\(category.id)'
                """
        ) == 0)
    }

    /// A refused write must leave the message log alone — a duplicate name
    /// that still emitted messages would push a row no client ever inserted.
    @Test func aRejectedDuplicateEmitsNothing() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        await #expect(throws: BudgetDatabase.CategoryWriteError.duplicateCategoryName(
            name: "groceries",
            groupName: "Daily"
        )) {
            try await store.createCategory(name: "groceries", groupId: "grp-daily")
        }

        #expect(try count(path: url, sql: "SELECT COUNT(*) FROM messages_crdt") == 0)
    }
}
