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

        let error = await #expect(throws: ActualServerError.self) {
            _ = try await store.awaitEnableBankingAuthorization(state: "state-1")
        }
        guard case .networkError(let cause as URLError) = error else {
            Issue.record("expected a network error, got \(String(describing: error))")
            return
        }
        #expect(cause.code == .secureConnectionFailed)
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

    private func enableBankingRemote(id: String, name: String = "Savings") -> BankSyncRemoteAccount {
        BankSyncRemoteAccount(
            id: id, name: name, institutionId: id, institutionName: "ING",
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

    // MARK: - Recognising a linked account after a new authorization

    @Test func anAccountIsRecognisedByTheTransactionsItSharesMostOf() {
        let matches = BudgetStore.accountMatches(
            imported: ["a": ["t1", "t2", "transfer"], "b": ["t9", "transfer"]],
            // A transfer between the two shows up on both sides under one id.
            returned: ["uid-1": ["t1", "t2", "transfer"], "uid-2": ["t9", "transfer", "t10"]]
        )
        #expect(matches == ["a": "uid-1", "b": "uid-2"])
    }

    @Test func nothingIsRecognisedWithoutAClearWinner() {
        // Shares nothing.
        #expect(BudgetStore.accountMatches(imported: ["a": ["t1"]], returned: ["uid-1": ["t9"]]).isEmpty)
        // Two returned accounts share equally much.
        #expect(BudgetStore.accountMatches(
            imported: ["a": ["transfer"]], returned: ["uid-1": ["transfer"], "uid-2": ["transfer"]]
        ).isEmpty)
        // Two budget accounts point at the same returned account.
        #expect(BudgetStore.accountMatches(
            imported: ["a": ["t1"], "b": ["t1"]], returned: ["uid-1": ["t1"]]
        ).isEmpty)
    }

    private nonisolated static func download(_ transactionIds: [String]) -> Data {
        let day = DayDate.today().adding(days: -5).iso
        let transactions = transactionIds.map {
            """
            {"transactionId":"\($0)","date":"\(day)","payeeName":"Shop","booked":true,
             "transactionAmount":{"amount":"-1.00"}}
            """
        }.joined(separator: ",")
        return Data("""
        {"status":"ok","data":{"transactions":{"all":[\(transactions)]},"balances":[],"startingBalance":0}}
        """.utf8)
    }

    /// Gives the linked account the imported transactions `bank-tx-1` and
    /// `bank-tx-2`.
    private func importTwoTransactions(into database: BudgetDatabase) async throws {
        let accountId = Self.accountId
        try await database.dbQueueForTesting.write { db in
            for id in ["tx-1", "tx-2"] {
                try db.execute(
                    sql: """
                    INSERT INTO transactions (id, acct, date, amount, cleared, tombstone, sort_order, financial_id)
                    VALUES (?, ?, 20260101, -100, 1, 0, 0, ?)
                    """,
                    arguments: [id, accountId, "bank-\(id)"]
                )
            }
        }
    }

    /// A server whose `/enablebanking/transactions` answers per bank account
    /// uid; a uid without transactions fails with a 500.
    private nonisolated static func downloads(_ byUid: [String: [String]]) -> StubTransport.Handler {
        { request in
            guard request.url?.path == "/enablebanking/transactions" else {
                return StubTransport.Response(status: 404)
            }
            let body = try JSONSerialization.jsonObject(with: request.bodyData) as? [String: Any]
            guard let ids = byUid[body?["accountId"] as? String ?? ""] else {
                return StubTransport.Response(status: 500)
            }
            return StubTransport.Response(body: download(ids))
        }
    }

    /// The linked account already holds two imported transactions; the bank
    /// returns the same account under a new uid next to another one.
    @Test func aLinkedAccountIsFoundAmongNewUidsByItsImportedTransactions() async throws {
        let (database, url) = try await makeDatabase(linked: true)
        defer { cleanup(url) }
        let accountId = Self.accountId
        try await importTwoTransactions(into: database)
        let asked = CallCounter()
        let store = try await makeStore(database: database) { request in
            guard request.url?.path == "/enablebanking/transactions" else {
                return StubTransport.Response(status: 404)
            }
            asked.increment()
            let body = try JSONSerialization.jsonObject(with: request.bodyData) as? [String: Any]
            let mine = body?["accountId"] as? String == "uid-new"
            return StubTransport.Response(body: Self.download(mine ? ["bank-tx-1", "bank-tx-2", "bank-tx-3"] : ["other-1"]))
        }
        let link = try #require(store.bankSyncAccounts.first { $0.id == accountId })
        let remotes = [enableBankingRemote(id: "uid-other"), enableBankingRemote(id: "uid-new")]

        let matches = await store.enableBankingMatches(for: [link], among: remotes)

        #expect(matches.mapValues(\.id) == [accountId: "uid-new"])
        #expect(asked.value == 2)
    }

    /// With nothing imported there is nothing to recognise an account by, so
    /// the bank isn't asked at all.
    @Test func anAccountWithoutImportedTransactionsAsksTheBankNothing() async throws {
        let (database, url) = try await makeDatabase(linked: true)
        defer { cleanup(url) }
        let asked = CallCounter()
        let store = try await makeStore(database: database) { _ in
            asked.increment()
            return StubTransport.Response(body: Self.download(["bank-tx-1"]))
        }
        let link = try #require(store.bankSyncAccounts.first { $0.id == Self.accountId })

        let matches = await store.enableBankingMatches(for: [link], among: [enableBankingRemote(id: "uid-new")])

        #expect(matches.isEmpty)
        #expect(asked.value == 0)
    }

    /// The account the link belongs to fails to download, and another one
    /// shares a transaction with it (a transfer between the two). Judged on
    /// what did arrive, the link would move to the wrong account.
    @Test func nothingIsRecognisedWhenADownloadFailed() async throws {
        let (database, url) = try await makeDatabase(linked: true)
        defer { cleanup(url) }
        try await importTwoTransactions(into: database)
        let store = try await makeStore(database: database, handler: Self.downloads(["uid-other": ["bank-tx-1"]]))
        let link = try #require(store.bankSyncAccounts.first { $0.id == Self.accountId })

        let matches = await store.enableBankingMatches(
            for: [link], among: [enableBankingRemote(id: "uid-mine"), enableBankingRemote(id: "uid-other")]
        )

        #expect(matches.isEmpty)
    }

    // MARK: - Which links an authorization renews

    /// Nothing was imported yet, so the transactions prove nothing. The
    /// returned account carries the linked account's name, which is enough
    /// when that account is being reauthorized and never when a bank is being
    /// connected: there it may be someone else's sign-in.
    @Test func onlyAReauthorizationRenewsWhatTheTransactionsDoNotProve() async throws {
        let (database, url) = try await makeDatabase(linked: true)
        defer { cleanup(url) }
        let asked = CallCounter()
        let store = try await makeStore(database: database) { _ in
            asked.increment()
            return StubTransport.Response(status: 404)
        }
        let remotes = [enableBankingRemote(id: "uid-new")]

        let connecting = await store.enableBankingRenewals(of: remotes, bankName: "ING", reauthorizing: nil)
        let reauthorizing = await store.enableBankingRenewals(
            of: remotes, bankName: "ING", reauthorizing: Self.accountId
        )

        #expect(connecting.isEmpty)
        #expect(reauthorizing.mapValues(\.id) == [Self.accountId: "uid-new"])
        // One account on each side needs no download to tell them apart.
        #expect(asked.value == 0)
    }

    /// By name the linked account would take `uid-named`; its transactions
    /// come back from `uid-mine`, and they decide.
    @Test func aReauthorizationGoesByTheTransactionsBeforeTheNames() async throws {
        let (database, url) = try await makeDatabase(linked: true)
        defer { cleanup(url) }
        try await importTwoTransactions(into: database)
        let store = try await makeStore(database: database, handler: Self.downloads([
            "uid-named": ["other-1"], "uid-mine": ["bank-tx-1", "bank-tx-2"],
        ]))
        let remotes = [enableBankingRemote(id: "uid-named"), enableBankingRemote(id: "uid-mine", name: "Main")]

        let renewals = await store.enableBankingRenewals(of: remotes, bankName: "ING", reauthorizing: Self.accountId)

        #expect(renewals.mapValues(\.id) == [Self.accountId: "uid-mine"])
    }

    /// Connecting the same bank again for a second account: the account that
    /// is already linked is recognised, the new one is left to set up.
    @Test func connectingABankAgainRenewsTheLinkItsTransactionsProve() async throws {
        let (database, url) = try await makeDatabase(linked: true)
        defer { cleanup(url) }
        try await importTwoTransactions(into: database)
        let store = try await makeStore(database: database, handler: Self.downloads([
            "uid-second": ["other-1"], "uid-mine": ["bank-tx-1", "bank-tx-2"],
        ]))
        let remotes = [enableBankingRemote(id: "uid-second", name: "Current"), enableBankingRemote(id: "uid-mine")]

        let renewals = await store.enableBankingRenewals(of: remotes, bankName: "ING", reauthorizing: nil)

        #expect(renewals.mapValues(\.id) == [Self.accountId: "uid-mine"])
    }
}
