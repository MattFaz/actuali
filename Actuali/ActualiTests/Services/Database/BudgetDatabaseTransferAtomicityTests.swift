import Foundation
import GRDB
import Testing
@testable import Actuali

struct BudgetDatabaseTransferAtomicityTests {
    private func transaction(
        id: String,
        accountId: String,
        amount: Int,
        transferId: String
    ) -> Transaction {
        Transaction(
            id: id,
            accountId: accountId,
            date: 20_260_610,
            amount: amount,
            payeeId: "payee-\(accountId)",
            payeeName: nil,
            categoryId: nil,
            categoryName: nil,
            notes: "transfer note",
            cleared: true,
            reconciled: false,
            transferId: transferId,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )
    }

    private func messages(for transactions: [Transaction]) -> [CRDTMessage] {
        var millis: Int64 = 1_700_000_000_000
        var result: [CRDTMessage] = []
        for txn in transactions {
            for (column, value) in txn.syncableFields {
                result.append(CRDTMessage(
                    timestamp: HLCTimestamp(millis: millis, counter: 0, node: "89e0e8e90b203f9e"),
                    dataset: Transaction.datasetName,
                    row: txn.id,
                    column: column,
                    value: CRDTValue.serialize(value)
                ))
                millis += 1
            }
        }
        return result
    }

    /// Synchronous so GRDB's `read` resolves to its synchronous overload and
    /// the non-Sendable rows never cross an isolation boundary.
    private func transactionRows(path: URL) throws -> [Row] {
        try DatabaseQueue(path: path.path).read { db in
            try Row.fetchAll(db, sql: "SELECT id, acct, amount, transferred_id FROM transactions ORDER BY amount")
        }
    }

    private func rowCount(path: URL, table: String) throws -> Int {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
        }
    }

    @Test func happyPathInsertsBothLegsMessagesAndLinkage() async throws {
        let (database, path) = try await makeTestDatabase(TestSchema.transactions, TestSchema.messagesCrdt)
        let sourceId = UUID().uuidString
        let targetId = UUID().uuidString
        let source = transaction(id: sourceId, accountId: "acct-from", amount: -1050, transferId: targetId)
        let target = transaction(id: targetId, accountId: "acct-to", amount: 1050, transferId: sourceId)
        let crdtMessages = messages(for: [source, target])

        let inserted = try database.insertTransfer(source: source, target: target, messages: crdtMessages)

        #expect(inserted.count == crdtMessages.count)
        #expect(try rowCount(path: path, table: "messages_crdt") == crdtMessages.count)

        let rows = try transactionRows(path: path)
        #expect(rows.count == 2)
        #expect(rows[0]["id"] == sourceId)
        #expect(rows[0]["acct"] == "acct-from")
        #expect(rows[0]["amount"] == -1050)
        #expect(rows[0]["transferred_id"] == targetId)
        #expect(rows[1]["id"] == targetId)
        #expect(rows[1]["acct"] == "acct-to")
        #expect(rows[1]["amount"] == 1050)
        #expect(rows[1]["transferred_id"] == sourceId)
    }

    @Test func convertingToATransferCommitsTheEditedRowAndItsNewPartner() async throws {
        let (database, path) = try await makeTestDatabase(TestSchema.transactions, TestSchema.messagesCrdt)
        let legId = UUID().uuidString
        let partnerId = UUID().uuidString
        // An ordinary transaction, before the conversion repoints it.
        var leg = transaction(id: legId, accountId: "acct-from", amount: -1050, transferId: partnerId)
        leg.transferId = nil
        try database.insertTransaction(leg)

        leg.transferId = partnerId
        let partner = transaction(id: partnerId, accountId: "acct-to", amount: 1050, transferId: legId)
        let crdtMessages = messages(for: [leg, partner])

        let inserted = try database.convertToTransfer(
            leg: leg, partner: partner, messages: crdtMessages
        )

        #expect(inserted.count == crdtMessages.count)
        let rows = try transactionRows(path: path)
        #expect(rows.count == 2)
        #expect(rows[0]["id"] == legId)
        #expect(rows[0]["transferred_id"] == partnerId)
        #expect(rows[1]["id"] == partnerId)
        #expect(rows[1]["transferred_id"] == legId)
    }

    @Test func partnerInsertFailureRollsBackTheEditedRowAndAllMessages() async throws {
        let (database, path) = try await makeTestDatabase(TestSchema.transactions, TestSchema.messagesCrdt)
        let legId = UUID().uuidString
        var leg = transaction(id: legId, accountId: "acct-from", amount: -1050, transferId: legId)
        leg.transferId = nil
        try database.insertTransaction(leg)

        // Same id as the row being converted: the partner INSERT violates the
        // primary key, simulating a persistence failure on the new leg.
        leg.transferId = legId
        let partner = transaction(id: legId, accountId: "acct-to", amount: 1050, transferId: legId)

        #expect(throws: (any Error).self) {
            try database.convertToTransfer(
                leg: leg, partner: partner, messages: self.messages(for: [leg, partner])
            )
        }

        // Atomicity: the edited row keeps no dangling link and no CRDT message
        // escaped to be pushed to the server.
        let queue = try DatabaseQueue(path: path.path)
        let transferredId = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT transferred_id FROM transactions WHERE id = ?", arguments: [legId])
        }
        #expect(transferredId == nil)
        #expect(try rowCount(path: path, table: "transactions") == 1)
        #expect(try rowCount(path: path, table: "messages_crdt") == 0)
    }

    @Test func secondLegFailureRollsBackFirstLegAndAllMessages() async throws {
        let (database, path) = try await makeTestDatabase(TestSchema.transactions, TestSchema.messagesCrdt)
        let sourceId = UUID().uuidString
        let source = transaction(id: sourceId, accountId: "acct-from", amount: -1050, transferId: sourceId)
        // Same id as the source leg: the second INSERT violates the primary
        // key, simulating a persistence failure on the second leg.
        let target = transaction(id: sourceId, accountId: "acct-to", amount: 1050, transferId: sourceId)
        let crdtMessages = messages(for: [source, target])

        #expect(throws: (any Error).self) {
            try database.insertTransfer(source: source, target: target, messages: crdtMessages)
        }

        // Atomicity: neither row nor any CRDT message survived the rollback
        #expect(try rowCount(path: path, table: "transactions") == 0)
        #expect(try rowCount(path: path, table: "messages_crdt") == 0)
    }
}
