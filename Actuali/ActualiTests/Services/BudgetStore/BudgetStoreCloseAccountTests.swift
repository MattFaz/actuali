import Foundation
import GRDB
import Testing
@testable import Actuali

/// Close and reopen (GH #654), mirroring upstream `closeAccount` /
/// `reopenAccount` in loot-core `server/accounts/app.ts`.
@MainActor
struct BudgetStoreCloseAccountTests {
    private func rows(path: URL, sql: String) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { try Row.fetchAll($0, sql: sql) }
    }

    private func current(_ store: BudgetStore, _ id: String) throws -> Account {
        try #require(store.accounts.first { $0.id == id })
    }

    @Test func zeroBalanceAccountWithHistoryIsOnlyMarkedClosed() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        let account = try await store.createAccount(name: "Old", offBudget: true, startingBalanceCents: 500)
        try await store.createAccount(name: "Other", offBudget: true, startingBalanceCents: 0)
        // Spend the balance so the account has history and nets to zero.
        let other = try #require(store.accounts.first { $0.name == "Other" })
        try await store.createTransfer(
            fromAccountId: account.id, toAccountId: other.id, amountCents: 500,
            date: Transaction.yyyymmdd(from: Date()), notes: nil, cleared: true
        )

        try await store.closeAccount(current(store, account.id), transferAccountId: nil)

        let closed = try rows(path: url, sql: "SELECT closed, tombstone FROM accounts WHERE id = '\(account.id)'")
        #expect(closed[0]["closed"] == 1)
        #expect(closed[0]["tombstone"] == 0)
        #expect(try rows(path: url, sql: "SELECT id FROM transactions WHERE notes = 'Closing account'").isEmpty)
    }

    @Test func nonZeroBalanceMovesToChosenAccount() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        let account = try await store.createAccount(name: "Old", offBudget: true, startingBalanceCents: 2500)
        let target = try await store.createAccount(name: "New", offBudget: true, startingBalanceCents: 0)

        try await store.closeAccount(current(store, account.id), transferAccountId: target.id)

        #expect(try current(store, account.id).closed)
        #expect(try current(store, account.id).balance == 0)
        #expect(try current(store, target.id).balance == 2500)
        let legs = try rows(path: url, sql: "SELECT acct, amount, date FROM transactions WHERE notes = 'Closing account' ORDER BY amount")
        #expect(legs.count == 2)
        #expect(legs[0]["amount"] == -2500)
        #expect(legs[0]["acct"] == account.id)
        #expect(legs[0]["date"] == Transaction.yyyymmdd(from: Date()))
    }

    @Test func negativeBalanceIsClearedByTransferringIn() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        let card = try await store.createAccount(name: "Card", offBudget: true, startingBalanceCents: -4000)
        let target = try await store.createAccount(name: "Bank", offBudget: true, startingBalanceCents: 10000)

        try await store.closeAccount(current(store, card.id), transferAccountId: target.id)

        #expect(try current(store, card.id).balance == 0)
        #expect(try current(store, target.id).balance == 6000)
    }

    @Test func nonZeroBalanceWithoutDestinationIsRejectedAndNothingChanges() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        let account = try await store.createAccount(name: "Old", offBudget: true, startingBalanceCents: 100)

        await #expect(throws: BudgetStoreError.missingTransferDestination) {
            try await store.closeAccount(account, transferAccountId: nil)
        }
        #expect(try !current(store, account.id).closed)
    }

    @Test func accountWithoutTransactionsIsDeleted() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        let account = try await store.createAccount(name: "Empty", offBudget: false, startingBalanceCents: 0)

        try await store.closeAccount(account, transferAccountId: nil)

        let row = try rows(path: url, sql: "SELECT closed, tombstone FROM accounts WHERE id = '\(account.id)'")
        #expect(row[0]["tombstone"] == 1)
        #expect(store.accounts.contains { $0.id == account.id } == false)
    }

    @Test func reopenClearsClosedFlag() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        let account = try await store.createAccount(name: "Old", offBudget: true, startingBalanceCents: 2500)
        let target = try await store.createAccount(name: "New", offBudget: true, startingBalanceCents: 0)
        try await store.closeAccount(current(store, account.id), transferAccountId: target.id)

        try await store.reopenAccount(current(store, account.id))

        #expect(try !current(store, account.id).closed)
        #expect(try rows(path: url, sql: "SELECT closed FROM accounts WHERE id = '\(account.id)'")[0]["closed"] == 0)
    }
}
