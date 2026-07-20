import Foundation
import Testing
import GRDB
@testable import Actuali

struct BudgetDatabaseTransferAtomicityTests {

    /// transactions and messages_crdt normally come from the downloaded budget
    /// file, so create them with the upstream schema (id PRIMARY KEY drives
    /// the failure-injection test; timestamp UNIQUE drives message dedup).
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    acct TEXT,
                    category TEXT,
                    amount INTEGER,
                    description TEXT,
                    notes TEXT,
                    date INTEGER,
                    imported_description TEXT,
                    financial_id TEXT,
                    transferred_id TEXT,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    parent_id TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                )
                """)
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func transaction(
        id: String,
        accountId: String,
        amount: Int,
        transferId: String
    ) -> Transaction {
        Transaction(
            id: id,
            accountId: accountId,
            date: 20260610,
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

    private func rowCount(path: URL, table: String) throws -> Int {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
        }
    }

    @Test func happyPathInsertsBothLegsMessagesAndLinkage() throws {
        let (database, path) = try makeDatabase()
        let sourceId = UUID().uuidString
        let targetId = UUID().uuidString
        let source = transaction(id: sourceId, accountId: "acct-from", amount: -1050, transferId: targetId)
        let target = transaction(id: targetId, accountId: "acct-to", amount: 1050, transferId: sourceId)
        let crdtMessages = messages(for: [source, target])

        let inserted = try database.insertTransfer(source: source, target: target, messages: crdtMessages)

        #expect(inserted.count == crdtMessages.count)
        #expect(try rowCount(path: path, table: "messages_crdt") == crdtMessages.count)

        let queue = try DatabaseQueue(path: path.path)
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, acct, amount, transferred_id FROM transactions ORDER BY amount")
        }
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

    @Test func secondLegFailureRollsBackFirstLegAndAllMessages() throws {
        let (database, path) = try makeDatabase()
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
