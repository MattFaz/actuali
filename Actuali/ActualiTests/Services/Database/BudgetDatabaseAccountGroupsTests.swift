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

    @Test func fetchUsesIdAsStableTieBreakerForEqualSortOrders() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO account_groups (id, name, sort_order, tombstone) VALUES
                    ('zulu', 'Zulu', 16384, 0),
                    ('alpha', 'Alpha', 16384, 0)
            """)
        }

        #expect(try await database.fetchAccountGroups().map(\.id) == ["alpha", "zulu"])
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

    @Test func movingAccountGroupPlacesItBeforeTarget() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        _ = try database.insertAccountGroup(id: "first", name: "First")
        _ = try database.insertAccountGroup(id: "middle", name: "Middle")
        _ = try database.insertAccountGroup(id: "last", name: "Last")

        let move = try database.moveAccountGroup(id: "last", before: "first")

        #expect(move.id == "last")
        #expect(try await database.fetchAccountGroups().map(\.id) == ["last", "first", "middle"])
    }

    /// Sort orders close enough to leave no midpoint force the neighbours to
    /// shift; those shifted rows are what the caller sends over CRDT too.
    @Test func movingAccountGroupPastATightNeighbourShovesItAndReportsIt() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO account_groups (id, name, sort_order, tombstone) VALUES
                    ('first', 'First', 1, 0),
                    ('middle', 'Middle', 2, 0),
                    ('last', 'Last', 3, 0)
            """)
        }

        let move = try database.moveAccountGroup(id: "last", before: "first")

        #expect(move.sortOrder == 0.5)
        #expect(move.movedSiblings == [
            SortOrder.Position(id: "first", sortOrder: SortOrder.increment + 1),
            SortOrder.Position(id: "middle", sortOrder: SortOrder.increment * 2 + 1),
        ])
        #expect(try await database.fetchAccountGroups().map(\.id) == ["last", "first", "middle"])
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

    @Test func migrationReplaysStoredAccountGroupAndAccountIdMessages() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }

        try await database.dbQueueForTesting.write { db in
            // Simulate an account with null account_group_id
            try db.execute(sql: "INSERT INTO accounts (id, name, sort_order, account_group_id) VALUES ('checking', 'Checking', 1000, NULL)")

            // Simulate messages_crdt storing account_groups and account_group_id messages
            // that were received before the local table was populated
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS messages_crdt (
                    id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL UNIQUE, dataset TEXT NOT NULL,
                    row TEXT NOT NULL, column TEXT NOT NULL, value BLOB NOT NULL
                )
            """)
            try db.execute(sql: """
                INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES
                    ('2026-10-01T10:00:00.000Z-0000-01', 'account_groups', 'cash', 'name', 'S:Cash Accounts'),
                    ('2026-10-01T10:00:00.000Z-0000-02', 'account_groups', 'cash', 'sort_order', 'N:16384'),
                    ('2026-10-01T10:00:00.000Z-0000-03', 'account_groups', 'cash', 'tombstone', 'N:0'),
                    ('2026-10-01T10:00:00.000Z-0000-04', 'account_groups', 'deleted', 'name', 'S:Old Group'),
                    ('2026-10-01T10:00:00.000Z-0000-05', 'account_groups', 'deleted', 'tombstone', 'N:1'),
                    ('2026-10-01T10:00:00.000Z-0000-06', 'accounts', 'checking', 'account_group_id', 'S:cash')
            """)

            // Remove the replay migration id if already recorded, to simulate an existing budget
            try db.execute(sql: "DELETE FROM __migrations__ WHERE id = ?", arguments: [BudgetDatabase.storedMessageReplayMigrationId])
        }

        // Re-open BudgetDatabase to trigger runPendingMigrations
        let reopened = try BudgetDatabase(path: path)

        let groups = try await reopened.fetchAccountGroups()
        #expect(groups.map(\.name) == ["Cash Accounts"])
        #expect(groups.first?.sortOrder == 16384)

        let accounts = try await reopened.fetchAccounts()
        #expect(accounts.first?.groupId == "cash")

        let applied = try await reopened.dbQueueForTesting.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM __migrations__ WHERE id = ?", arguments: [BudgetDatabase.storedMessageReplayMigrationId])
        }
        #expect(applied == BudgetDatabase.storedMessageReplayMigrationId)
    }
}
