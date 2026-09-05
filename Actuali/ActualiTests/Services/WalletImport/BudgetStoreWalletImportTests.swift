import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreWalletImportTests {

    /// Upstream schema, matching BudgetStoreSaveTransactionTests (real budget
    /// files always have financial_id — it's Actual's bank-import dedup key).
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    starting_balance_flag INTEGER DEFAULT 0,
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
                CREATE TABLE payees (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    transfer_acct TEXT,
                    tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE payee_mapping (
                    id TEXT PRIMARY KEY,
                    targetId TEXT
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

    private func makeStore(database: BudgetDatabase) async throws -> BudgetStore {
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)
        return store
    }

    private func transactionRows(path: URL) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM transactions ORDER BY financial_id")
        }
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func candidate(
        id: String,
        amountCents: Int = -820,
        payeeName: String = "Blue Bottle",
        date: Date = Date(timeIntervalSince1970: 1_750_000_000),
        cleared: Bool = true
    ) -> WalletImportCandidate {
        WalletImportCandidate(
            id: id, amountCents: amountCents, payeeName: payeeName,
            date: date, cleared: cleared
        )
    }

    @Test func importWritesRowsWithFinancialId() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        let result = try await store.importWalletTransactions([
            candidate(id: "aaa-1", amountCents: -820, payeeName: "Blue Bottle"),
            candidate(id: "aaa-2", amountCents: 1500, payeeName: "Refund", cleared: false)
        ], accountId: "acct-1")

        #expect(result == BudgetStore.WalletImportResult(imported: 2, skippedDuplicates: 0))

        let rows = try transactionRows(path: url)
        #expect(rows.count == 2)
        #expect(rows[0]["financial_id"] == "aaa-1")
        #expect(rows[0]["amount"] == -820)
        #expect(rows[0]["cleared"] == 1)
        #expect(rows[0]["acct"] == "acct-1")
        #expect(rows[1]["financial_id"] == "aaa-2")
        #expect(rows[1]["amount"] == 1500)
        #expect(rows[1]["cleared"] == 0)

        // Payee resolved and linked (description column holds the payee id).
        let payeeId: String? = rows[0]["description"]
        #expect(payeeId != nil)
    }

    @Test func importEmitsFinancialIdCRDTMessage() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        _ = try await store.importWalletTransactions(
            [candidate(id: "bbb-1")], accountId: "acct-1")

        let queue = try DatabaseQueue(path: url.path)
        let financialIdMessages = try await queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messages_crdt
                WHERE dataset = 'transactions' AND column = 'financial_id'
                """) ?? 0
        }
        #expect(financialIdMessages == 1)
    }

    @Test func reimportSkipsExistingFinancialIds() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        _ = try await store.importWalletTransactions(
            [candidate(id: "ccc-1"), candidate(id: "ccc-2")], accountId: "acct-1")
        let second = try await store.importWalletTransactions(
            [candidate(id: "ccc-1"), candidate(id: "ccc-2"), candidate(id: "ccc-3")],
            accountId: "acct-1")

        #expect(second == BudgetStore.WalletImportResult(imported: 1, skippedDuplicates: 2))
        #expect(try transactionRows(path: url).count == 3)
    }

    @Test func duplicateWithinBatchImportsOnce() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        let result = try await store.importWalletTransactions(
            [candidate(id: "ddd-1"), candidate(id: "ddd-1")], accountId: "acct-1")

        #expect(result == BudgetStore.WalletImportResult(imported: 1, skippedDuplicates: 1))
        #expect(try transactionRows(path: url).count == 1)
    }

    @Test func deletedImportStaysDeletedOnReimport() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        _ = try await store.importWalletTransactions(
            [candidate(id: "eee-1")], accountId: "acct-1")
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "UPDATE transactions SET tombstone = 1")
        }

        let second = try await store.importWalletTransactions(
            [candidate(id: "eee-1")], accountId: "acct-1")
        #expect(second == BudgetStore.WalletImportResult(imported: 0, skippedDuplicates: 1))
    }

    @Test func manualSaveLeavesFinancialIdNull() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        try await store.saveTransaction(BudgetStore.TransactionForm(
            accountId: "acct-1",
            type: .expense,
            amount: "10.50",
            payeeName: "Corner Shop",
            transferToAccountId: nil,
            categoryId: nil,
            notes: "",
            date: Date(),
            cleared: true,
            recordLocation: false
        ))

        let rows = try transactionRows(path: url)
        #expect(rows.count == 1)
        let financialId: String? = rows[0]["financial_id"]
        #expect(financialId == nil)

        let queue = try DatabaseQueue(path: url.path)
        let financialIdMessages = try await queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messages_crdt WHERE column = 'financial_id'
                """) ?? 0
        }
        #expect(financialIdMessages == 0)
    }
}
