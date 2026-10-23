import Foundation
import GRDB
import Testing
@testable import Actuali

/// Account drag-and-drop and the account-group write gate: what lands in
/// SQLite and which columns go out over CRDT.
@MainActor
struct BudgetStoreAccountGroupTests {
    private func makeStore(groupWrites: Bool) async throws -> (BudgetStore, BudgetDatabase, URL) {
        let (database, url) = try await makeTestDatabase(
            TestSchema.accounts, TestSchema.messagesCrdt,
            """
            CREATE TABLE account_groups (
                id TEXT PRIMARY KEY, name TEXT, sort_order REAL, tombstone INTEGER DEFAULT 0
            );
            INSERT INTO accounts (id, name, sort_order) VALUES
                ('x', 'X', 16384.0), ('a', 'A', 32768.0), ('b', 'B', 49152.0);
            """
        )
        let store = try await makeTestStore(database: database)
        store.setAccountGroupWritesEnabledForTesting(groupWrites)
        store.accounts = [("x", 16384), ("a", 32768), ("b", 49152)].map {
            Account(id: $0.0, name: $0.0.uppercased(), type: .checking, offBudget: false,
                    closed: false, sortOrder: $0.1, balance: 0)
        }
        return (store, database, url)
    }

    private func order(_ database: BudgetDatabase) async throws -> [String] {
        try await database.dbQueueForTesting.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM accounts ORDER BY sort_order, id")
        }
    }

    private func messagedColumns(_ database: BudgetDatabase, row: String) async throws -> [String] {
        try await database.dbQueueForTesting.read { db in
            try String.fetchAll(db, sql: "SELECT column FROM messages_crdt WHERE row = ? ORDER BY column", arguments: [row])
        }
    }

    @Test func dropAtTheEndMovesItToTheEnd() async throws {
        let (store, database, url) = try await makeStore(groupWrites: true)
        defer { cleanup(url) }

        try await store.dropAccount("x", at: 3, among: store.accounts, groupId: nil)

        #expect(try await order(database) == ["a", "b", "x"])
    }

    @Test func dropOnItsOwnSlotLeavesTheOrderAlone() async throws {
        let (store, database, url) = try await makeStore(groupWrites: true)
        defer { cleanup(url) }

        // List reports index 0, which is the dragged account itself; the
        // neighbour below it is the anchor, not an append.
        try await store.dropAccount("x", at: 0, among: store.accounts, groupId: nil)

        #expect(try await order(database) == ["x", "a", "b"])
    }

    @Test func reorderWorksWithoutGroupSupportAndSendsOnlySortOrder() async throws {
        let (store, database, url) = try await makeStore(groupWrites: false)
        defer { cleanup(url) }

        try await store.dropAccount("x", at: 2, among: store.accounts, groupId: nil)

        #expect(try await order(database) == ["a", "x", "b"])
        // A pre-26.9 server has no account_group_id column to accept.
        #expect(try await messagedColumns(database, row: "x") == ["sort_order"])
    }

    @Test func movingAccountGroupPersistsAndSyncsItsOrder() async throws {
        let (store, database, url) = try await makeStore(groupWrites: true)
        defer { cleanup(url) }
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO account_groups (id, name, sort_order, tombstone) VALUES
                    ('cash', 'Cash', 16384, 0),
                    ('savings', 'Savings', 32768, 0),
                    ('brokerage', 'Brokerage', 49152, 0)
            """)
        }

        try await store.moveAccountGroup(id: "brokerage", before: "cash")

        #expect(try await database.fetchAccountGroups().map(\.id) == ["brokerage", "cash", "savings"])
        let sortOrderMessages = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messages_crdt
                WHERE dataset = 'account_groups' AND row = 'brokerage' AND column = 'sort_order'
            """) ?? 0
        }
        #expect(sortOrderMessages == 1)
    }

    @Test func groupWritesAreSkippedWithoutServerSupport() async throws {
        let (store, database, url) = try await makeStore(groupWrites: false)
        defer { cleanup(url) }

        let cash = AccountGroup(id: "cash", name: "Cash", sortOrder: 16384)
        try await store.createAccountGroup(name: "Savings")
        try await store.renameAccountGroup(cash, name: "Wallet")
        try await store.deleteAccountGroup(cash)
        try await store.setAccountGroup(store.accounts[0], groupId: "cash")
        try await store.moveAccountGroup(id: "cash", before: nil)
        // A drag across groups is a group change too.
        try await store.dropAccount("x", at: 0, among: store.accounts, groupId: "cash")

        let messageCount = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0
        }
        #expect(messageCount == 0)
    }

    @Test func droppingIntoAGroupSendsTheGroupColumn() async throws {
        let (store, database, url) = try await makeStore(groupWrites: true)
        defer { cleanup(url) }

        try await store.dropAccount("x", at: 0, among: store.accounts, groupId: "cash")

        #expect(try await messagedColumns(database, row: "x") == ["account_group_id", "sort_order"])
    }
}
