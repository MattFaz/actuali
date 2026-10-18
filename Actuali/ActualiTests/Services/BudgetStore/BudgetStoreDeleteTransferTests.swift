import Foundation
import GRDB
import Testing
@testable import Actuali

/// Deleting one leg of a transfer removes its partner too (GH #724), as
/// upstream's `transfer.ts` `removeTransfer` does — except a partner that is a
/// split child, which is unlinked instead so its split stays whole and saveable.
@MainActor
struct BudgetStoreDeleteTransferTests {
    private func tombstones(path: URL) throws -> [String: Int] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT id, tombstone FROM transactions").map {
                ($0["id"] as String, $0["tombstone"] as Int)
            })
        }
    }

    private func leg(_ id: String, account: String, amount: Int, transferId: String?) -> Transaction {
        Transaction(
            id: id, accountId: account, date: 20_260_610, amount: amount,
            payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: transferId,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 1000,
            importedPayee: nil
        )
    }

    private func seedTransfer(_ database: BudgetDatabase) async throws {
        try await database.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, description, transferred_id, sort_order) VALUES
                    ('leg-out',   'acct-checking', -2500, 20260610, 'payee-savings',  'leg-in',  2),
                    ('leg-in',    'acct-savings',   2500, 20260610, 'payee-checking', 'leg-out', 1),
                    ('bystander', 'acct-checking',  -200, 20260610, NULL,             NULL,      0);
            """)
        }
    }

    @Test func deletingOneLegTombstonesItsPartner() async throws {
        let (database, path) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(path) }
        let store = try await makeTestStore(database: database)
        try await seedTransfer(database)

        await store.deleteTransaction(leg("leg-out", account: "acct-checking", amount: -2500, transferId: "leg-in"))

        #expect(try tombstones(path: path) == ["leg-out": 1, "leg-in": 1, "bystander": 0])
        #expect(store.error == nil)
    }

    @Test func deletingBothLegsTogetherTombstonesEachOnce() async throws {
        let (database, path) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(path) }
        let store = try await makeTestStore(database: database)
        try await seedTransfer(database)

        await store.deleteTransactions([
            leg("leg-out", account: "acct-checking", amount: -2500, transferId: "leg-in"),
            leg("leg-in", account: "acct-savings", amount: 2500, transferId: "leg-out"),
        ])

        #expect(try tombstones(path: path) == ["leg-out": 1, "leg-in": 1, "bystander": 0])
        let tombstoneMessages = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE column = 'tombstone'")
        }
        #expect(tombstoneMessages == 2)
    }

    @Test func deletingALegWhosePartnerIsASplitChildUnlinksTheChild() async throws {
        let (database, path) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(path) }
        let store = try await makeTestStore(database: database)
        try await database.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, description, transferred_id, isParent, isChild, parent_id, sort_order) VALUES
                    ('parent', 'acct-checking', -2500, 20260610, 'payee-shop',     NULL,     1, 0, NULL,     3),
                    ('child',  'acct-checking', -2500, 20260610, 'payee-savings',  'leg-in', 0, 1, 'parent', 2),
                    ('leg-in', 'acct-savings',   2500, 20260610, 'payee-checking', 'child',  0, 0, NULL,     1);
            """)
        }

        await store.deleteTransaction(leg("leg-in", account: "acct-savings", amount: 2500, transferId: "child"))

        #expect(try tombstones(path: path) == ["leg-in": 1, "child": 0, "parent": 0])
        // A dangling link would make the split's next save throw
        // transferPartnerMissing.
        let child = try await database.dbQueueForTesting.read { db in
            try Row.fetchOne(db, sql: "SELECT transferred_id, description FROM transactions WHERE id = 'child'")
                .map { (transferId: $0["transferred_id"] as String?, payeeId: $0["description"] as String?) }
        }
        #expect(child?.transferId == nil)
        #expect(child?.payeeId == nil)
        #expect(store.error == nil)
    }
}
