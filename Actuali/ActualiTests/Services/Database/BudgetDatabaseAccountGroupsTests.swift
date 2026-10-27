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

    /// Stores `values` in messages_crdt as if they synced before this file
    /// had anywhere to put them, and forgets the listed migration ids.
    private func storeUnappliedMessages(
        _ values: [(dataset: String, row: String, column: String, value: String)],
        path: URL,
        forgetting migrationIds: [Int64]
    ) throws {
        try DatabaseQueue(path: path.path).write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS messages_crdt (
                    id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL UNIQUE, dataset TEXT NOT NULL,
                    row TEXT NOT NULL, column TEXT NOT NULL, value BLOB NOT NULL
                )
            """)
            for (index, message) in values.enumerated() {
                try db.execute(
                    sql: "INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES (?, ?, ?, ?, ?)",
                    arguments: [
                        "2026-10-01T10:00:00.000Z-000\(index)-0000000000000001",
                        message.dataset, message.row, message.column, message.value,
                    ]
                )
            }
            for id in migrationIds {
                try db.execute(sql: "DELETE FROM __migrations__ WHERE id = ?", arguments: [id])
            }
        }
    }

    private let storedGroupMessages = [
        (dataset: "account_groups", row: "cash", column: "name", value: "S:Cash Accounts"),
        (dataset: "account_groups", row: "cash", column: "sort_order", value: "N:16384"),
        (dataset: "account_groups", row: "cash", column: "tombstone", value: "N:0"),
        (dataset: "account_groups", row: "deleted", column: "name", value: "S:Old Group"),
        (dataset: "account_groups", row: "deleted", column: "tombstone", value: "N:1"),
    ]

    @Test func reopenReplaysStoredMessagesIntoTablesCreatedByAnEarlierVersion() async throws {
        let (_, path) = try await makeDatabase()
        defer { cleanup(path) }
        try storeUnappliedMessages(
            storedGroupMessages, path: path,
            forgetting: [BudgetDatabase.storedMessageReplayMigrationId]
        )

        let reopened = try BudgetDatabase(path: path)

        let groups = try await reopened.fetchAccountGroups()
        #expect(groups.map(\.name) == ["Cash Accounts"])
        #expect(groups.first?.sortOrder == 16384)
        // Recorded, so the next open takes no write lock.
        #expect(try await reopened.dbQueueForTesting.read { try !BudgetDatabase.pendingMigrationWork($0) })
    }

    @Test func createTableMigrationReplaysStoredMessagesAfterTheOneOffReplay() async throws {
        let (_, path) = try await makeTestDatabase(TestSchema.accounts)
        defer { cleanup(path) }
        // A future create-table migration: the one-off replay already ran,
        // and the table arrives with this update.
        try await DatabaseQueue(path: path.path).write { try $0.execute(sql: "DROP TABLE account_groups") }
        try storeUnappliedMessages(storedGroupMessages, path: path, forgetting: [1_787_013_118_115])

        let reopened = try BudgetDatabase(path: path)

        #expect(try await reopened.fetchAccountGroups().map(\.name) == ["Cash Accounts"])
    }

    @Test func replaySkipsInternalTablesAServerCannotTarget() async throws {
        let (_, path) = try await makeDatabase()
        defer { cleanup(path) }
        // bank_sync_local_links is device-local and keyed by account_id,
        // so applyMessages never writes it. A stored message for it must not
        // make the file unopenable.
        try storeUnappliedMessages(
            [(dataset: "bank_sync_local_links", row: "checking", column: "source", value: "S:hostile")],
            path: path,
            forgetting: [BudgetDatabase.storedMessageReplayMigrationId]
        )

        let reopened = try BudgetDatabase(path: path)

        let links = try await reopened.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bank_sync_local_links")
        }
        #expect(links == 0)
    }
}
