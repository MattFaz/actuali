import Foundation
import GRDB
import Testing
@testable import Actuali

struct SyncClientAccountGroupsTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL, SyncClient) {
        let (database, path) = try await makeTestDatabase(TestSchema.accounts, TestSchema.messagesCrdt)
        let syncClient = try await makeTestSyncClient(database: database)
        return (database, path, syncClient)
    }

    @Test func createAccountGroupPersistsItAndEmitsCRDTFields() async throws {
        let (database, path, syncClient) = try await makeDatabase()
        defer { cleanup(path) }

        try await syncClient.createAccountGroup(id: "cash", name: "Cash Accounts")

        #expect(try await database.fetchAccountGroups().map(\.name) == ["Cash Accounts"])
        let columns = try await database.dbQueueForTesting.read { db in
            try String.fetchAll(db, sql: "SELECT column FROM messages_crdt WHERE dataset = 'account_groups' AND row = 'cash'")
        }
        #expect(Set(columns) == ["name", "sort_order", "tombstone"])
    }

    @Test func renameAccountGroupUpdatesItsNameAndCRDTMessage() async throws {
        let (database, path, syncClient) = try await makeDatabase()
        defer { cleanup(path) }
        try await syncClient.createAccountGroup(id: "cash", name: "Cash")

        try await syncClient.updateAccountGroup(id: "cash", name: "Cash Accounts")

        #expect(try await database.fetchAccountGroups().map(\.name) == ["Cash Accounts"])
        let count = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messages_crdt
                WHERE dataset = 'account_groups' AND row = 'cash' AND column = 'name'
            """) ?? 0
        }
        #expect(count == 2)
    }

    @Test func deletingGroupUnassignsAccountsAndEmitsTombstoneAndDetachMessages() async throws {
        let (database, path, syncClient) = try await makeDatabase()
        defer { cleanup(path) }
        try await syncClient.createAccountGroup(id: "cash", name: "Cash")
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "INSERT INTO accounts (id, name, account_group_id) VALUES ('checking', 'Checking', 'cash')")
        }

        try await syncClient.deleteAccountGroup(id: "cash")

        #expect(try await database.fetchAccountGroups().isEmpty)
        let rows = try await database.dbQueueForTesting.read { db in
            try (
                Int.fetchOne(db, sql: "SELECT tombstone FROM account_groups WHERE id = 'cash'") ?? 0,
                String.fetchOne(db, sql: "SELECT account_group_id FROM accounts WHERE id = 'checking'")
            )
        }
        #expect(rows.0 == 1)
        #expect(rows.1 == nil)
        let detachMessageCount = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messages_crdt
                WHERE dataset = 'accounts' AND row = 'checking' AND column = 'account_group_id'
            """) ?? 0
        }
        #expect(detachMessageCount == 1)
    }

    @Test func movingAccountGroupPersistsOrderAndEmitsSortOrderMessages() async throws {
        let (database, path, syncClient) = try await makeDatabase()
        defer { cleanup(path) }
        try await syncClient.createAccountGroup(id: "cash", name: "Cash")
        try await syncClient.createAccountGroup(id: "savings", name: "Savings")
        try await syncClient.createAccountGroup(id: "brokerage", name: "Brokerage")

        try await syncClient.moveAccountGroup(id: "brokerage", before: "cash")

        #expect(try await database.fetchAccountGroups().map(\.id) == ["brokerage", "cash", "savings"])
        let sortOrderMessages = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messages_crdt
                WHERE dataset = 'account_groups' AND row = 'brokerage' AND column = 'sort_order'
            """) ?? 0
        }
        #expect(sortOrderMessages == 2)
    }

    /// A move that has to shift neighbours emits their sort_order too, or the
    /// other clients keep the old gaps and render a different order.
    @Test func movingAccountGroupEmitsSortOrderForEveryShovedSibling() async throws {
        let (database, path, syncClient) = try await makeDatabase()
        defer { cleanup(path) }
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO account_groups (id, name, sort_order, tombstone) VALUES
                    ('first', 'First', 1, 0),
                    ('middle', 'Middle', 2, 0),
                    ('last', 'Last', 3, 0)
            """)
        }

        try await syncClient.moveAccountGroup(id: "last", before: "first")

        #expect(try await database.fetchAccountGroups().map(\.id) == ["last", "first", "middle"])
        let sortOrderRows = try await database.dbQueueForTesting.read { db in
            try String.fetchAll(db, sql: """
                SELECT row FROM messages_crdt
                WHERE dataset = 'account_groups' AND column = 'sort_order'
                ORDER BY row
            """)
        }
        #expect(sortOrderRows == ["first", "last", "middle"])
    }

    @Test func assigningAndClearingGroupEmitsAccountGroupMessages() async throws {
        let (database, path, syncClient) = try await makeDatabase()
        defer { cleanup(path) }
        try await syncClient.createAccountGroup(id: "cash", name: "Cash")
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "INSERT INTO accounts (id, name) VALUES ('checking', 'Checking')")
        }

        try await syncClient.setAccountGroup(accountId: "checking", groupId: "cash")
        try await syncClient.setAccountGroup(accountId: "checking", groupId: nil)

        let account = try await database.dbQueueForTesting.read { db in
            try String.fetchOne(db, sql: "SELECT account_group_id FROM accounts WHERE id = 'checking'")
        }
        #expect(account == nil)
        let messages = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messages_crdt
                WHERE dataset = 'accounts' AND row = 'checking' AND column = 'account_group_id'
            """) ?? 0
        }
        #expect(messages == 2)
    }
}
