import Foundation
import GRDB
import Testing
@testable import Actuali

/// Account type selector (GH #676). Upstream Actual defines no account types,
/// so the type is Actuali's own value in the nullable `accounts.type` column.
@MainActor
struct BudgetStoreAccountTypeTests {
    private func rows(path: URL, sql: String) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { try Row.fetchAll($0, sql: sql) }
    }

    @Test func createdAccountKeepsTheChosenType() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        let account = try await store.createAccount(
            name: "Home Loan", offBudget: true, startingBalanceCents: 0, type: .mortgage
        )

        #expect(try rows(path: url, sql: "SELECT type FROM accounts WHERE id = '\(account.id)'")[0]["type"] == "mortgage")
        #expect(store.accounts.first { $0.id == account.id }?.type == .mortgage)
    }

    @Test func changingTheTypeSavesAndSyncsIt() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        let account = try await store.createAccount(name: "Card", offBudget: false, startingBalanceCents: 0)

        try await store.setAccountType(account, type: .credit)

        #expect(store.accounts.first { $0.id == account.id }?.type == .credit)
        #expect(try rows(path: url, sql: "SELECT type FROM accounts WHERE id = '\(account.id)'")[0]["type"] == "credit")
        let columns = try rows(
            path: url,
            sql: "SELECT column FROM messages_crdt WHERE dataset = 'accounts' AND row = '\(account.id)'"
        ).map { $0["column"] as String }
        #expect(columns.contains("type"))
    }

    @Test func choosingTheSameTypeWritesNothing() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        let account = try await store.createAccount(name: "Plain", offBudget: false, startingBalanceCents: 0)
        let before = try rows(path: url, sql: "SELECT COUNT(*) AS n FROM messages_crdt")[0]["n"] as Int

        try await store.setAccountType(account, type: account.type)

        #expect(try rows(path: url, sql: "SELECT COUNT(*) AS n FROM messages_crdt")[0]["n"] as Int == before)
    }

    @Test func unknownAndMissingStoredTypesReadAsCheckingAndAreLeftAlone() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        let known = try await store.createAccount(name: "Known", offBudget: false, startingBalanceCents: 0, type: .savings)
        try await DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: "UPDATE accounts SET type = 'brokerage' WHERE id = ?", arguments: [known.id])
        }

        let other = try await store.createAccount(name: "Blank", offBudget: false, startingBalanceCents: 0)
        try await DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: "UPDATE accounts SET type = NULL WHERE id = ?", arguments: [other.id])
        }
        let reloaded = try await BudgetDatabase(path: url).fetchAccounts()

        #expect(reloaded.first { $0.id == known.id }?.type == .checking)
        #expect(reloaded.first { $0.id == other.id }?.type == .checking)
        // Reading never rewrites what is stored.
        #expect(try rows(path: url, sql: "SELECT type FROM accounts WHERE id = '\(known.id)'")[0]["type"] == "brokerage")
        #expect(try rows(path: url, sql: "SELECT type FROM accounts WHERE id = '\(other.id)'")[0]["type"] as String? == nil)
    }

    @Test func everyTypeHasATitle() {
        #expect(AccountType.allCases.allSatisfy { !$0.title.isEmpty && !$0.title.hasPrefix("accounts.type.") })
    }
}
