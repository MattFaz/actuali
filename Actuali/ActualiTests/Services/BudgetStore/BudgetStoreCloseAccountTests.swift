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

    @Test func onBudgetIntoOffBudgetCategorizesTheClosingLeg() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        let checking = try await store.createAccount(name: "Checking", offBudget: false, startingBalanceCents: 2500)
        let brokerage = try await store.createAccount(name: "Brokerage", offBudget: true, startingBalanceCents: 0)

        try await store.closeAccount(current(store, checking.id), transferAccountId: brokerage.id, categoryId: "cat-x")

        let legs = try rows(path: url, sql: "SELECT acct, category FROM transactions WHERE notes = 'Closing account'")
        #expect(legs.count == 2)
        let checkingLeg = try #require(legs.first { $0["acct"] == checking.id })
        let brokerageLeg = try #require(legs.first { $0["acct"] == brokerage.id })
        #expect(checkingLeg["category"] as String? == "cat-x")
        #expect(brokerageLeg["category"] as String? == nil)
    }

    /// The transfer runs before the close, so a refused transfer leaves the
    /// account open with its balance rather than closed with money stranded.
    @Test func aRefusedTransferLeavesTheAccountOpen() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        let account = try await store.createAccount(name: "Old", offBudget: true, startingBalanceCents: 2500)
        let target = try await store.createAccount(name: "New", offBudget: true, startingBalanceCents: 0)
        store.payees.removeAll { $0.transferAccountId == target.id }

        await #expect(throws: BudgetStoreError.transferPayeeMissing) {
            try await store.closeAccount(current(store, account.id), transferAccountId: target.id)
        }
        #expect(try rows(path: url, sql: "SELECT closed FROM accounts WHERE id = '\(account.id)'")[0]["closed"] == 0)
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

/// Force close (GH #654): upstream `closeAccount(forced: true)`.
@MainActor
struct BudgetStoreForceCloseAccountTests {
    private func rows(path: URL, sql: String) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { try Row.fetchAll($0, sql: sql) }
    }

    @Test func removesAccountTransactionsAndPayeeAndUnlinksPartner() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        let doomed = try await store.createAccount(name: "Doomed", offBudget: true, startingBalanceCents: 900)
        let other = try await store.createAccount(name: "Other", offBudget: true, startingBalanceCents: 0)
        try await store.createTransfer(
            fromAccountId: doomed.id, toAccountId: other.id, amountCents: 300,
            date: Transaction.yyyymmdd(from: Date()), notes: nil, cleared: true
        )
        let doomedPayeeId = try #require(store.transferPayee(forAccountId: doomed.id)?.id)

        try await store.forceCloseAccount(#require(store.accounts.first { $0.id == doomed.id }))

        #expect(try rows(path: url, sql: "SELECT tombstone FROM accounts WHERE id = '\(doomed.id)'")[0]["tombstone"] == 1)
        #expect(try rows(path: url, sql: "SELECT id FROM transactions WHERE acct = '\(doomed.id)' AND tombstone = 0").isEmpty)
        #expect(try rows(path: url, sql: "SELECT tombstone FROM payees WHERE id = '\(doomedPayeeId)'")[0]["tombstone"] == 1)
        // The other side of the transfer survives without its payee or link.
        let partner = try rows(path: url, sql: "SELECT description, transferred_id, tombstone FROM transactions WHERE acct = '\(other.id)' AND amount = 300")
        #expect(partner.count == 1)
        #expect(partner[0]["tombstone"] == 0)
        #expect(partner[0]["transferred_id"] as String? == nil)
        #expect(partner[0]["description"] as String? == nil)
        #expect(store.accounts.contains { $0.id == doomed.id } == false)
    }

    @Test func writesUpstreamMessagesForEveryRowIncludingSplits() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = BudgetStore.previewInstance()
        let syncClient = try await makeTestSyncClient(database: database)
        store.configureForTesting(database: database, syncClient: syncClient)
        let doomed = try await store.createAccount(name: "Doomed", offBudget: true, startingBalanceCents: 900)
        let other = try await store.createAccount(name: "Other", offBudget: true, startingBalanceCents: 0)
        let today = Transaction.yyyymmdd(from: Date())
        try await store.createTransfer(
            fromAccountId: doomed.id, toAccountId: other.id, amountCents: 300,
            date: today, notes: nil, cleared: true
        )
        func split(_ id: String, amount: Int, parentId: String?) -> Transaction {
            Transaction(
                id: id, accountId: doomed.id, date: today, amount: amount,
                payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
                notes: nil, cleared: true, reconciled: false, transferId: nil,
                isParent: parentId == nil, parentId: parentId, tombstone: false, sortOrder: 0
            )
        }
        try await syncClient.createSplit(
            parent: split("split", amount: -300, parentId: nil),
            children: [split("child-1", amount: -100, parentId: "split"), split("child-2", amount: -200, parentId: "split")]
        )
        let payeeId = try #require(store.transferPayee(forAccountId: doomed.id)?.id)
        let liveIds = try rows(path: url, sql: "SELECT id FROM transactions WHERE acct = '\(doomed.id)' AND tombstone = 0")
            .compactMap { $0["id"] as String? }
        #expect(Set(liveIds).isSuperset(of: ["split", "child-1", "child-2"]))
        let partnerId: String = try #require(
            rows(path: url, sql: "SELECT id FROM transactions WHERE acct = '\(other.id)' AND amount = 300").first?["id"]
        )
        let before: Int = try #require(rows(path: url, sql: "SELECT MAX(id) AS id FROM messages_crdt").first?["id"])

        try await store.forceCloseAccount(#require(store.accounts.first { $0.id == doomed.id }))

        let messages = try rows(path: url, sql: "SELECT dataset, row, column FROM messages_crdt WHERE id > \(before)")
        func columns(_ dataset: String, _ row: String) -> Set<String> {
            Set(messages.filter { $0["dataset"] == dataset && $0["row"] == row }.compactMap { $0["column"] as String? })
        }
        for id in liveIds {
            #expect(columns("transactions", id) == ["tombstone"])
        }
        #expect(columns("transactions", partnerId) == ["description", "transferred_id"])
        #expect(columns("accounts", doomed.id) == ["tombstone"])
        #expect(columns("payees", payeeId) == ["tombstone"])
    }
}
