import Foundation
import GRDB
import Testing
@testable import Actuali

/// Account creation (PR #199): the store must mirror the PWA's own
/// `createAccount` — an accounts row, the account's transfer payee (the
/// empty-named payee transfers resolve through), and an opening-balance
/// transaction only when the balance is nonzero, categorized to the income
/// category for on-budget accounts.
@MainActor
struct BudgetStoreCreateAccountTests {
    /// An "Income" group whose second category is Starting Balances, so a
    /// test can tell "picked by name" apart from "picked because it's first".
    private func incomeGroups() -> [CategoryGroup] {
        [CategoryGroup(
            id: "grp-income",
            name: "Income",
            isIncome: true,
            hidden: false,
            sortOrder: 0,
            categories: [
                Category(id: "cat-income", name: "Income", groupId: "grp-income",
                         isIncome: true, hidden: false, sortOrder: 0),
                Category(id: "cat-starting", name: "Starting Balances", groupId: "grp-income",
                         isIncome: true, hidden: false, sortOrder: 1),
            ]
        )]
    }

    private func rows(path: URL, sql: String) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: sql)
        }
    }

    private func count(path: URL, sql: String) throws -> Int {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Int.fetchOne(db, sql: sql) ?? 0
        }
    }

    @Test func createPersistsAccountTransferPayeeAndOpeningBalance() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        let account = try await store.createAccount(
            name: "  Savings  ", offBudget: false, startingBalanceCents: 12345
        )

        let accountRows = try rows(path: url, sql: "SELECT * FROM accounts")
        #expect(accountRows.count == 1)
        #expect(accountRows[0]["id"] == account.id)
        #expect(accountRows[0]["name"] == "Savings")
        #expect(accountRows[0]["offbudget"] == 0)
        #expect(accountRows[0]["closed"] == 0)
        #expect(accountRows[0]["tombstone"] == 0)

        // The transfer payee: empty name, carries transfer_acct, and has the
        // self-mapping row the transaction joins resolve through.
        let transferPayees = try rows(
            path: url, sql: "SELECT * FROM payees WHERE transfer_acct IS NOT NULL"
        )
        #expect(transferPayees.count == 1)
        #expect(transferPayees[0]["name"] == "")
        #expect(transferPayees[0]["transfer_acct"] == account.id)
        let transferPayeeId: String = transferPayees[0]["id"]
        #expect(try count(
            path: url,
            sql: "SELECT COUNT(*) FROM payee_mapping WHERE id = '\(transferPayeeId)' AND targetId = '\(transferPayeeId)'"
        ) == 1)

        // The opening balance: full amount, flagged, cleared, from the shared
        // "Starting Balance" payee (a separate payee from the transfer one).
        let txnRows = try rows(path: url, sql: "SELECT * FROM transactions")
        #expect(txnRows.count == 1)
        #expect(txnRows[0]["acct"] == account.id)
        #expect(txnRows[0]["amount"] == 12345)
        #expect(txnRows[0]["starting_balance_flag"] == 1)
        #expect(txnRows[0]["cleared"] == 1)
        let payeeId: String? = txnRows[0]["description"]
        #expect(payeeId != nil)
        #expect(payeeId != transferPayeeId)
        #expect(try count(
            path: url,
            sql: "SELECT COUNT(*) FROM payees WHERE name = 'Starting Balance'"
        ) == 1)
    }

    @Test func createEmitsCRDTMessagesForEveryRow() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        let account = try await store.createAccount(
            name: "Checking", offBudget: false, startingBalanceCents: 500
        )

        let transferPayeeId: String = try rows(
            path: url, sql: "SELECT id FROM payees WHERE transfer_acct IS NOT NULL"
        )[0]["id"]

        // One message per synced column, same shape as every other write.
        #expect(try count(
            path: url,
            sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'accounts' AND row = '\(account.id)'"
        ) == 6)
        #expect(try count(
            path: url,
            sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'payees' AND row = '\(transferPayeeId)'"
        ) == 3)
        #expect(try count(
            path: url,
            sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'payee_mapping' AND row = '\(transferPayeeId)'"
        ) == 1)
        #expect(try count(
            path: url,
            sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'transactions' AND column = 'starting_balance_flag'"
        ) == 1)
    }

    @Test func onBudgetOpeningBalanceTakesTheStartingBalancesCategory() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        store.categoryGroups = incomeGroups()

        try await store.createAccount(
            name: "Checking", offBudget: false, startingBalanceCents: 1000
        )

        let txnRows = try rows(path: url, sql: "SELECT category FROM transactions")
        #expect(txnRows.count == 1)
        #expect(txnRows[0]["category"] == "cat-starting")
    }

    @Test func openingBalanceFallsBackToTheFirstIncomeCategory() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        var groups = incomeGroups()
        groups[0].categories.removeAll { $0.name == "Starting Balances" }
        store.categoryGroups = groups

        try await store.createAccount(
            name: "Checking", offBudget: false, startingBalanceCents: 1000
        )

        let txnRows = try rows(path: url, sql: "SELECT category FROM transactions")
        #expect(txnRows.count == 1)
        #expect(txnRows[0]["category"] == "cat-income")
    }

    @Test func offBudgetOpeningBalanceStaysUncategorized() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        store.categoryGroups = incomeGroups()

        try await store.createAccount(
            name: "Brokerage", offBudget: true, startingBalanceCents: 99900
        )

        let txnRows = try rows(path: url, sql: "SELECT category, amount FROM transactions")
        #expect(txnRows.count == 1)
        let category: String? = txnRows[0]["category"]
        #expect(category == nil)
        #expect(txnRows[0]["amount"] == 99900)
    }

    @Test func zeroBalanceSkipsTheOpeningTransaction() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        try await store.createAccount(
            name: "Empty", offBudget: false, startingBalanceCents: 0
        )

        // No transaction and no "Starting Balance" payee — only the account
        // and its transfer payee, exactly like the PWA.
        #expect(try count(path: url, sql: "SELECT COUNT(*) FROM transactions") == 0)
        #expect(try count(path: url, sql: "SELECT COUNT(*) FROM accounts") == 1)
        let payeeRows = try rows(path: url, sql: "SELECT name, transfer_acct FROM payees")
        #expect(payeeRows.count == 1)
        #expect(payeeRows[0]["name"] == "")
        let transferAcct: String? = payeeRows[0]["transfer_acct"]
        #expect(transferAcct != nil)
    }

    @Test func blankNameIsRejectedAndNothingPersists() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        await #expect(throws: BudgetStoreError.invalidAccountName) {
            try await store.createAccount(
                name: "   ", offBudget: false, startingBalanceCents: 100
            )
        }

        #expect(try count(path: url, sql: "SELECT COUNT(*) FROM accounts") == 0)
        #expect(try count(path: url, sql: "SELECT COUNT(*) FROM payees") == 0)
        #expect(try count(path: url, sql: "SELECT COUNT(*) FROM messages_crdt") == 0)
    }

    @Test func openingBalanceFailureRollsBackAccountAndPayee() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }

        // Pre-insert a row so the opening-balance INSERT violates the primary
        // key, simulating a persistence failure on the last row of the batch.
        let collidingId = UUID().uuidString
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO transactions (id) VALUES (?)",
                arguments: [collidingId]
            )
        }

        let account = Account(
            id: UUID().uuidString, name: "Doomed", type: .checking,
            offBudget: false, closed: false, sortOrder: 1, balance: 100
        )
        let transferPayee = Payee(
            id: UUID().uuidString, name: "", transferAccountId: account.id, tombstone: false
        )
        let openingBalance = Transaction(
            id: collidingId,
            accountId: account.id,
            date: 20_260_812,
            amount: 100,
            payeeId: nil,
            payeeName: nil,
            categoryId: nil,
            categoryName: nil,
            notes: nil,
            cleared: true,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil,
            startingBalanceFlag: true
        )

        #expect(throws: (any Error).self) {
            try database.insertAccount(
                account, transferPayee: transferPayee,
                startingBalanceTransaction: openingBalance
            )
        }

        // Atomicity: the account and payee rolled back with the transaction.
        #expect(try count(path: url, sql: "SELECT COUNT(*) FROM accounts") == 0)
        #expect(try count(path: url, sql: "SELECT COUNT(*) FROM payees") == 0)
        #expect(try count(path: url, sql: "SELECT COUNT(*) FROM payee_mapping") == 0)
    }
}
