import Foundation
import GRDB
import Testing
@testable import Actuali

/// Moving a category between and within groups: what lands in SQLite and what
/// goes out over CRDT. Mirrors upstream `category/move`: the category's own
/// `cat_group` and `sort_order`, plus a `sort_order` message for each sibling
/// the shove had to displace.
@MainActor
struct BudgetStoreMoveCategoryTests {
    private func makeDatabase(extra: String = "") async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(
            TestSchema.categories, TestSchema.categoryGroups, TestSchema.categoryMapping,
            TestSchema.messagesCrdt,
            """
            INSERT INTO category_groups (id, name, sort_order) VALUES
                ('grp-daily', 'Daily', 16384.0),
                ('grp-fun', 'Fun', 32768.0);
            INSERT INTO categories (id, name, cat_group, sort_order) VALUES
                ('cat-groceries', 'Groceries', 'grp-daily', 16384.0),
                ('cat-fuel', 'Fuel', 'grp-daily', 32768.0),
                ('cat-rent', 'Rent', 'grp-daily', 49152.0),
                ('cat-games', 'Games', 'grp-fun', 16384.0);
            INSERT INTO category_mapping (id, transferId) VALUES
                ('cat-groceries', 'cat-groceries'), ('cat-fuel', 'cat-fuel'),
                ('cat-rent', 'cat-rent'), ('cat-games', 'cat-games');
            \(extra)
            """
        )
    }

    private func rows(path: URL, sql: String) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: sql)
        }
    }

    /// The group's category ids top to bottom, the way the Budget tab orders them.
    private func order(path: URL, group: String) throws -> [String] {
        try rows(
            path: path,
            sql: "SELECT id FROM categories WHERE cat_group = '\(group)' AND tombstone IS NOT 1 ORDER BY sort_order, id"
        ).map { $0["id"] as String }
    }

    /// The columns a row's messages covered, sorted for a stable assertion.
    private func messagedColumns(path: URL, row: String) throws -> [String] {
        try rows(
            path: path,
            sql: "SELECT column FROM messages_crdt WHERE dataset = 'categories' AND row = '\(row)'"
        )
        .map { $0["column"] as String }
        .sorted()
    }

    @Test func movingWithinAGroupPlacesItBeforeTheTarget() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        try await store.moveCategory(id: "cat-rent", toGroup: "grp-daily", before: "cat-groceries", month: "2026-07")

        #expect(try order(path: url, group: "grp-daily") == ["cat-rent", "cat-groceries", "cat-fuel"])
        // The gap is wide, so nothing else has to move: only the category's
        // own two columns are messaged.
        #expect(try messagedColumns(path: url, row: "cat-rent") == ["cat_group", "sort_order"])
        #expect(try messagedColumns(path: url, row: "cat-groceries").isEmpty)
        #expect(try messagedColumns(path: url, row: "cat-fuel").isEmpty)
    }

    @Test func movingDownWithinAGroupLandsBetweenTheNeighbours() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        try await store.moveCategory(id: "cat-groceries", toGroup: "grp-daily", before: "cat-rent", month: "2026-07")

        #expect(try order(path: url, group: "grp-daily") == ["cat-fuel", "cat-groceries", "cat-rent"])
    }

    @Test func movingToAnotherGroupChangesItsGroupAndPosition() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        try await store.moveCategory(id: "cat-groceries", toGroup: "grp-fun", before: "cat-games", month: "2026-07")

        #expect(try order(path: url, group: "grp-fun") == ["cat-groceries", "cat-games"])
        #expect(try order(path: url, group: "grp-daily") == ["cat-fuel", "cat-rent"])
        let message = try rows(
            path: url,
            sql: "SELECT value FROM messages_crdt WHERE dataset = 'categories' AND row = 'cat-groceries' AND column = 'cat_group'"
        )
        #expect(message.count == 1)
        #expect(message[0]["value"] == "S:grp-fun")
    }

    @Test func movingWithoutATargetAppendsToTheGroup() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        try await store.moveCategory(id: "cat-groceries", toGroup: "grp-fun", before: nil, month: "2026-07")

        #expect(try order(path: url, group: "grp-fun") == ["cat-games", "cat-groceries"])
        let sortOrder: Double = try rows(
            path: url,
            sql: "SELECT sort_order FROM categories WHERE id = 'cat-groceries'"
        )[0]["sort_order"]
        #expect(sortOrder == 16384.0 + SortOrder.increment)
    }

    @Test func aClosedGapShovesTheSiblingsAndMessagesThem() async throws {
        // Two neighbours one apart leave no midpoint, so the target and what
        // follows are pushed up by a full increment first.
        let (database, url) = try await makeDatabase(extra: """
        UPDATE categories SET sort_order = 100.0 WHERE id = 'cat-groceries';
        UPDATE categories SET sort_order = 101.0 WHERE id = 'cat-fuel';
        UPDATE categories SET sort_order = 102.0 WHERE id = 'cat-rent';
        """)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        try await store.moveCategory(id: "cat-games", toGroup: "grp-daily", before: "cat-fuel", month: "2026-07")

        #expect(try order(path: url, group: "grp-daily") == ["cat-groceries", "cat-games", "cat-fuel", "cat-rent"])
        // The displaced siblings are messaged by their sort_order alone.
        #expect(try messagedColumns(path: url, row: "cat-fuel") == ["sort_order"])
        #expect(try messagedColumns(path: url, row: "cat-rent") == ["sort_order"])
        #expect(try messagedColumns(path: url, row: "cat-games") == ["cat_group", "sort_order"])
    }

    @Test func movingIntoAMissingGroupOrOfAMissingCategoryIsRefused() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        await #expect(throws: BudgetDatabase.CategoryWriteError.groupNotFound) {
            try await store.moveCategory(id: "cat-rent", toGroup: "grp-nope", before: nil, month: "2026-07")
        }
        await #expect(throws: BudgetDatabase.CategoryWriteError.categoryNotFound) {
            try await store.moveCategory(id: "cat-nope", toGroup: "grp-fun", before: nil, month: "2026-07")
        }
        #expect(try rows(path: url, sql: "SELECT 1 FROM messages_crdt").isEmpty)
        #expect(try order(path: url, group: "grp-daily") == ["cat-groceries", "cat-fuel", "cat-rent"])
    }

    // MARK: - Groups

    /// The group ids top to bottom, as the Budget tab orders them.
    private func groupOrder(path: URL) throws -> [String] {
        try rows(path: path, sql: "SELECT id FROM category_groups WHERE tombstone IS NOT 1 ORDER BY sort_order, id")
            .map { $0["id"] as String }
    }

    @Test func movingAGroupPlacesItBeforeTheTarget() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        try await store.moveCategoryGroup(id: "grp-fun", before: "grp-daily", month: "2026-07")

        #expect(try groupOrder(path: url) == ["grp-fun", "grp-daily"])
        let columns = try rows(
            path: url,
            sql: "SELECT column FROM messages_crdt WHERE dataset = 'category_groups' AND row = 'grp-fun'"
        ).map { $0["column"] as String }
        #expect(columns == ["sort_order"])
        #expect(try rows(path: url, sql: "SELECT 1 FROM messages_crdt WHERE row = 'grp-daily'").isEmpty)
    }

    @Test func movingAGroupWithoutATargetPutsItLast() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        try await store.moveCategoryGroup(id: "grp-daily", before: nil, month: "2026-07")

        #expect(try groupOrder(path: url) == ["grp-fun", "grp-daily"])
    }

    @Test func aClosedGapBetweenGroupsShovesTheOthersAndMessagesThem() async throws {
        let (database, url) = try await makeDatabase(extra: """
        INSERT INTO category_groups (id, name, sort_order) VALUES ('grp-bills', 'Bills', 32769.0);
        UPDATE category_groups SET sort_order = 100.0 WHERE id = 'grp-daily';
        UPDATE category_groups SET sort_order = 101.0 WHERE id = 'grp-fun';
        UPDATE category_groups SET sort_order = 102.0 WHERE id = 'grp-bills';
        """)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        try await store.moveCategoryGroup(id: "grp-bills", before: "grp-fun", month: "2026-07")

        #expect(try groupOrder(path: url) == ["grp-daily", "grp-bills", "grp-fun"])
        let shoved = try rows(
            path: url,
            sql: "SELECT row FROM messages_crdt WHERE dataset = 'category_groups' AND column = 'sort_order'"
        ).map { $0["row"] as String }
        #expect(Set(shoved) == ["grp-fun", "grp-bills"])
    }

    @Test func movingAMissingGroupIsRefused() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        await #expect(throws: BudgetDatabase.CategoryWriteError.groupNotFound) {
            try await store.moveCategoryGroup(id: "grp-nope", before: nil, month: "2026-07")
        }
        #expect(try rows(path: url, sql: "SELECT 1 FROM messages_crdt").isEmpty)
    }
}
