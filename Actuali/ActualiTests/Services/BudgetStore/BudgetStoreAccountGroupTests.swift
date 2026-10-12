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

    @Test func dropBelowTheLastAccountMovesItToTheEnd() async throws {
        let (store, database, url) = try await makeStore(groupWrites: true)
        defer { cleanup(url) }

        try await store.dropAccount("x", on: "b", after: true)

        #expect(try await order(database) == ["a", "b", "x"])
    }

    @Test func reorderWorksWithoutGroupSupportAndSendsOnlySortOrder() async throws {
        let (store, database, url) = try await makeStore(groupWrites: false)
        defer { cleanup(url) }

        try await store.dropAccount("x", on: "b", after: false)

        #expect(try await order(database) == ["a", "x", "b"])
        // A pre-26.9 server has no account_group_id column to accept.
        #expect(try await messagedColumns(database, row: "x") == ["sort_order"])
    }

    @Test func groupWritesAreSkippedWithoutServerSupport() async throws {
        let (store, database, url) = try await makeStore(groupWrites: false)
        defer { cleanup(url) }
        store.accountGroups = [AccountGroup(id: "cash", name: "Cash", sortOrder: 16384)]

        try await store.createAccountGroup(name: "Savings")
        try await store.dropAccountIntoGroup("x", groupId: "cash")

        let messageCount = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0
        }
        #expect(messageCount == 0)
    }

    @Test func droppingIntoAGroupSendsTheGroupColumn() async throws {
        let (store, database, url) = try await makeStore(groupWrites: true)
        defer { cleanup(url) }
        store.accountGroups = [AccountGroup(id: "cash", name: "Cash", sortOrder: 16384)]

        try await store.dropAccountIntoGroup("x", groupId: "cash")

        #expect(try await messagedColumns(database, row: "x") == ["account_group_id", "sort_order"])
    }
}
