import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actuali

/// A class, because a noncopyable `Mutex` can't be captured by an escaping closure.
private final class CallCounter: Sendable {
    private let count = Mutex(0)

    var value: Int {
        count.withLock { $0 }
    }

    @discardableResult
    func increment() -> Int {
        count.withLock { total in
            total += 1
            return total
        }
    }
}

@MainActor
struct BudgetStoreEnableBankingLinkTests {
    private static let accountId = "acct-eb"

    private static let pollSuccess = """
    {"status":"ok","data":{"session_id":"s-1","accounts":[
      {"account_id":"uid-B","name":"Savings","institution":"ING","balance":12345}
    ],"aspsp":{"name":"ING","country":"NL"}}}
    """

    /// A budget with one account, optionally already linked via Enable Banking
    /// under uid-A with a `last_sync`.
    private func makeDatabase(linked: Bool = false) async throws -> (BudgetDatabase, URL) {
        var statements = TestSchema.core + [TestSchema.preferences, TestSchema.rules]
        if linked {
            statements.append("INSERT INTO banks (id, bank_id, name) VALUES ('bank-old', 'uid-A', 'ING')")
            statements.append("""
            INSERT INTO accounts (id, name, type, offbudget, closed, tombstone, sort_order,
                                  account_id, account_sync_source, bank)
            VALUES ('\(Self.accountId)', 'Savings', 'savings', 0, 0, 0, 1,
                    'uid-A', 'enableBanking', 'bank-old')
            """)
        } else {
            statements.append("""
            INSERT INTO accounts (id, name, type, offbudget, closed, tombstone, sort_order)
            VALUES ('\(Self.accountId)', 'Savings', 'savings', 0, 0, 0, 1)
            """)
        }
        return try await makeTestDatabase(statements)
    }

    private func makeStore(
        database: BudgetDatabase,
        handler: @escaping StubTransport.Handler = { _ in StubTransport.Response(status: 404) }
    ) async throws -> BudgetStore {
        let store = try await makeTestStore(database: database)
        let serverClient = ActualServerClient(session: StubTransport.session(handler))
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("session-token")
        store.setServerClientForTesting(serverClient)
        await store.loadBankSyncAccounts()
        return store
    }

    /// The account columns the link tests assert on, projected inside the `read`
    /// closure so the non-Sendable `Row` never leaves it (see AGENTS.md).
    private struct AccountRow: Sendable {
        let accountId: String?
        let syncSource: String?
        let bank: String?
        let lastSync: String?
    }

    private func accountRow(path: URL) throws -> AccountRow? {
        try DatabaseQueue(path: path.path).read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT account_id, account_sync_source, bank, last_sync FROM accounts WHERE id = ?",
                arguments: [Self.accountId]
            ).map {
                AccountRow(
                    accountId: $0["account_id"], syncSource: $0["account_sync_source"],
                    bank: $0["bank"], lastSync: $0["last_sync"]
                )
            }
        }
    }

    private func bankRow(path: URL, id: String?) throws -> (bankId: String?, name: String?)? {
        try DatabaseQueue(path: path.path).read { db in
            try Row.fetchOne(db, sql: "SELECT bank_id, name FROM banks WHERE id = ?", arguments: [id]).map {
                (bankId: $0["bank_id"], name: $0["name"])
            }
        }
    }

    // MARK: - Authorization

    @Test func pollingRetriesAfterATransportFailure() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let calls = CallCounter()
        let success = Data(Self.pollSuccess.utf8)
        let store = try await makeStore(database: database) { request in
            guard request.url?.path == "/enablebanking/poll-auth" else {
                return StubTransport.Response(status: 404)
            }
            if calls.increment() == 1 {
                throw URLError(.networkConnectionLost)
            }
            return StubTransport.Response(body: success)
        }

        let accounts = try await store.awaitEnableBankingAuthorization(state: "state-1")

        #expect(calls.value == 2)
        #expect(accounts.count == 1)
        #expect(accounts[0].id == "uid-B")
        #expect(accounts[0].institutionId == accounts[0].id)
        #expect(accounts[0].institutionName == "ING")
        #expect(accounts[0].source == .enableBanking)
    }

    /// A reverse proxy can answer the open long-poll while the person is still
    /// at their bank.
    @Test func pollingKeepsWaitingAfterAGatewayTimeout() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let calls = CallCounter()
        let success = Data(Self.pollSuccess.utf8)
        let store = try await makeStore(database: database) { _ in
            if calls.increment() == 1 {
                return StubTransport.Response(status: 504)
            }
            return StubTransport.Response(body: success)
        }

        let accounts = try await store.awaitEnableBankingAuthorization(state: "state-1")

        #expect(calls.value == 2)
        #expect(accounts.map(\.id) == ["uid-B"])
    }

    @Test func pollingGivesUpAtOnceOnAFailureARetryCannotFix() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let calls = CallCounter()
        let store = try await makeStore(database: database) { _ in
            calls.increment()
            throw URLError(.secureConnectionFailed)
        }

        let error = await #expect(throws: URLError.self) {
            _ = try await store.awaitEnableBankingAuthorization(state: "state-1")
        }
        #expect(error?.code == .secureConnectionFailed)
        #expect(calls.value == 1)
    }

    @Test func aServerErrorIsNotRetried() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let calls = CallCounter()
        let store = try await makeStore(database: database) { _ in
            calls.increment()
            return StubTransport.Response(body: Data(#"{"status":"ok","data":{"error":"Polling timed out"}}"#.utf8))
        }

        await #expect(throws: EnableBankingAuthError.timedOut) {
            _ = try await store.awaitEnableBankingAuthorization(state: "state-1")
        }
        #expect(calls.value == 1)
    }

    // MARK: - Linking

    private func enableBankingRemote(id: String) -> BankSyncRemoteAccount {
        BankSyncRemoteAccount(
            id: id, name: "Savings", institutionId: id, institutionName: "ING",
            balanceCents: 12345, source: .enableBanking
        )
    }

    @Test func linkingWritesTheColumnsTheWebUIReads() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        try await store.linkBankAccount(accountId: Self.accountId, to: enableBankingRemote(id: "uid-B"))

        let account = try #require(try accountRow(path: url))
        #expect(account.accountId == "uid-B")
        #expect(account.syncSource == "enableBanking")
        #expect(account.bank != nil)

        let bank = try #require(try bankRow(path: url, id: account.bank))
        #expect(bank.bankId == "uid-B")
        #expect(bank.name == "ING")
    }

    /// Re-authorizing issues new uids, so the existing account is re-linked
    /// onto them; its sync history stays.
    @Test func relinkingAfterReauthorizationReplacesTheUidAndKeepsLastSync() async throws {
        let (database, url) = try await makeDatabase(linked: true)
        defer { cleanup(url) }
        let accountId = Self.accountId
        try await database.dbQueueForTesting.write { db in
            try db.execute(
                sql: "UPDATE accounts SET last_sync = ? WHERE id = ?",
                arguments: ["1600000000000", accountId]
            )
        }
        let store = try await makeStore(database: database)

        try await store.linkBankAccount(accountId: Self.accountId, to: enableBankingRemote(id: "uid-B"))

        let account = try #require(try accountRow(path: url))
        #expect(account.accountId == "uid-B")
        #expect(account.syncSource == "enableBanking")
        #expect(account.lastSync == "1600000000000")
    }
}
