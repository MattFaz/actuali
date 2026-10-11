import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetDatabaseAccountGroupsTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(
            TestSchema.accounts,
            """
            CREATE TABLE account_groups (
                id TEXT PRIMARY KEY, name TEXT, sort_order REAL, tombstone INTEGER DEFAULT 0
            )
            """
        )
    }

    @Test func insertAppendsAfterActiveGroupsAndFetchHidesTombstones() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO account_groups (id, name, sort_order, tombstone) VALUES
                    ('first', 'First', 16384, 0),
                    ('deleted', 'Deleted', 65536, 1),
                    ('last', 'Last', 32768, 0)
            """)
        }

        let inserted = try database.insertAccountGroup(id: "new", name: "New")

        #expect(inserted.sortOrder == 32768 + SortOrder.increment)
        #expect(try await database.fetchAccountGroups().map(\.id) == ["first", "last", "new"])
    }

    @Test func renameUpdatesThePersistedGroup() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        _ = try database.insertAccountGroup(id: "cash", name: "Cash")

        try database.renameAccountGroup(id: "cash", name: "Cash Accounts")

        #expect(try await database.fetchAccountGroups().map(\.name) == ["Cash Accounts"])
    }

    @Test func setAccountGroupCanAssignAndRemoveAnAccount() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        _ = try database.insertAccountGroup(id: "cash", name: "Cash")
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "INSERT INTO accounts (id, name, account_group_id) VALUES ('checking', 'Checking', NULL)")
        }

        try database.setAccountGroup(accountId: "checking", groupId: "cash")
        let assigned: String? = try await database.dbQueueForTesting.read { db in
            try String.fetchOne(db, sql: "SELECT account_group_id FROM accounts WHERE id = 'checking'")
        }
        #expect(assigned == "cash")

        try database.setAccountGroup(accountId: "checking", groupId: nil)
        let unassigned: String? = try await database.dbQueueForTesting.read { db in
            try String.fetchOne(db, sql: "SELECT account_group_id FROM accounts WHERE id = 'checking'")
        }
        #expect(unassigned == nil)
    }

    @Test func deletingGroupUnassignsMembersAndTombstonesIt() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        _ = try database.insertAccountGroup(id: "cash", name: "Cash")
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO accounts (id, name, account_group_id) VALUES
                    ('checking', 'Checking', 'cash'), ('savings', 'Savings', 'cash')
            """)
        }

        #expect(try Set(database.deleteAccountGroup(id: "cash")) == ["checking", "savings"])
        #expect(try await database.fetchAccountGroups().isEmpty)
        let remaining = try await database.dbQueueForTesting.read { db in
            try String.fetchAll(db, sql: "SELECT account_group_id FROM accounts WHERE account_group_id IS NOT NULL")
        }
        #expect(remaining.isEmpty)
    }

    @Test func movingAccountChangesItsGroupAndPlacesItBeforeTarget() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        _ = try database.insertAccountGroup(id: "cash", name: "Cash")
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO accounts (id, name, sort_order, account_group_id) VALUES
                    ('source', 'Source', 16384, NULL),
                    ('target', 'Target', 32768, 'cash'),
                    ('after', 'After', 49152, 'cash')
            """)
        }

        let move = try database.moveAccount(accountId: "source", toGroupId: "cash", beforeAccountId: "target")

        #expect(move.accountId == "source")
        #expect(move.groupId == "cash")
        #expect(move.sortOrder == 16384)
        let order = try await database.dbQueueForTesting.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM accounts WHERE account_group_id = 'cash' ORDER BY sort_order, id")
        }
        #expect(order == ["source", "target", "after"])
    }
}
