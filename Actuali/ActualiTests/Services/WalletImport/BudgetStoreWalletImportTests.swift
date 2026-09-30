import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreWalletImportTests {
    /// Real budget files always have financial_id — it's Actual's bank-import
    /// dedup key — and rules, which can suppress an import.
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.core + [TestSchema.rules])
    }

    private func transactionRows(path: URL) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM transactions ORDER BY financial_id")
        }
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
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        let result = try await store.importWalletTransactions([
            candidate(id: "aaa-1", amountCents: -820, payeeName: "Blue Bottle"),
            candidate(id: "aaa-2", amountCents: 1500, payeeName: "Refund", cleared: false),
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
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        _ = try await store.importWalletTransactions(
            [candidate(id: "bbb-1")], accountId: "acct-1"
        )

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
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        _ = try await store.importWalletTransactions(
            [candidate(id: "ccc-1"), candidate(id: "ccc-2")], accountId: "acct-1"
        )
        let second = try await store.importWalletTransactions(
            [candidate(id: "ccc-1"), candidate(id: "ccc-2"), candidate(id: "ccc-3")],
            accountId: "acct-1"
        )

        #expect(second == BudgetStore.WalletImportResult(imported: 1, skippedDuplicates: 2))
        #expect(try transactionRows(path: url).count == 3)
    }

    @Test func sameFinancialIdCanBeImportedIntoDifferentAccounts() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        let first = try await store.importWalletTransactions(
            [candidate(id: "shared-wallet-id")], accountId: "acct-1"
        )
        let second = try await store.importWalletTransactions(
            [candidate(id: "shared-wallet-id")], accountId: "acct-2"
        )
        let sameAccountRetry = try await store.importWalletTransactions(
            [candidate(id: "shared-wallet-id")], accountId: "acct-2"
        )

        #expect(first == BudgetStore.WalletImportResult(imported: 1, skippedDuplicates: 0))
        #expect(second == BudgetStore.WalletImportResult(imported: 1, skippedDuplicates: 0))
        #expect(sameAccountRetry == BudgetStore.WalletImportResult(imported: 0, skippedDuplicates: 1))
        #expect(try transactionRows(path: url).filter { row in
            let financialId: String? = row["financial_id"]
            return financialId == "shared-wallet-id"
        }.map { row in
            let accountId: String? = row["acct"]
            return accountId
        }.compactMap(\.self).sorted() == ["acct-1", "acct-2"])
    }

    @Test func duplicateWithinBatchImportsOnce() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        let result = try await store.importWalletTransactions(
            [candidate(id: "ddd-1"), candidate(id: "ddd-1")], accountId: "acct-1"
        )

        #expect(result == BudgetStore.WalletImportResult(imported: 1, skippedDuplicates: 1))
        #expect(try transactionRows(path: url).count == 1)
    }

    @Test func deletedImportStaysDeletedOnReimport() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        _ = try await store.importWalletTransactions(
            [candidate(id: "eee-1")], accountId: "acct-1"
        )
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "UPDATE transactions SET tombstone = 1")
        }

        let second = try await store.importWalletTransactions(
            [candidate(id: "eee-1")], accountId: "acct-1"
        )
        #expect(second == BudgetStore.WalletImportResult(imported: 0, skippedDuplicates: 1))
    }

    @Test func ruleSuppressionIsNotCountedAsImportedOrDuplicate() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
            INSERT INTO rules (id, conditions, actions, tombstone, conditions_op)
            VALUES ('suppress-coffee',
                '[{"op":"contains","field":"imported_description","value":"Coffee"}]',
                '[{"op":"delete-transaction","value":null}]', 0, 'and')
            """)
        }

        let result = try await store.importWalletTransactions(
            [candidate(id: "suppressed-1", payeeName: "Coffee")], accountId: "acct-1"
        )

        #expect(result == BudgetStore.WalletImportResult(imported: 0, skippedDuplicates: 0))
        #expect(try transactionRows(path: url).isEmpty)
    }

    @Test func manualSaveLeavesFinancialIdNull() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

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
