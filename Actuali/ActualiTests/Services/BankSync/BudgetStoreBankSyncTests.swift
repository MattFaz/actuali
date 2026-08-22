import Foundation
import GRDB
import Testing
@testable import Actuali

/// Serves one canned SimpleFIN account set to every request.
private final class BridgeTransport: URLProtocol {
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var requestedURLs: [URL] = []

    static func makeSession(body: String) -> URLSession {
        Self.body = body
        Self.requestedURLs = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BridgeTransport.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedURLs.append(request.url!)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Answers the `/simplefin/*` routes by path.
private final class ServerTransport: URLProtocol {
    nonisolated(unsafe) static var bodies: [String: String] = [:]
    nonisolated(unsafe) static var requestedPaths: [String] = []

    static func makeSession(_ bodies: [String: String]) -> URLSession {
        Self.bodies = bodies
        Self.requestedPaths = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerTransport.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.requestedPaths.append(path)
        let body = Self.bodies[path]
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: body == nil ? 404 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct BudgetStoreBankSyncTests {

    private static let accountId = "acct-1"
    private static let externalAccountId = "sf-acct-1"

    /// Timestamps relative to now, so the download always lands inside the
    /// 90-day sync window however long this test lives.
    private static func daysAgo(_ days: Int) -> Int {
        Int(Date().timeIntervalSince1970) - days * 86_400
    }

    private static func expectedDay(_ days: Int) -> Int {
        SimpleFINAmount.day(fromTimestamp: daysAgo(days))
    }

    private func accountSet(
        balance: String = "100.00",
        transactions: String
    ) -> String {
        """
        {"errors": [], "accounts": [{
          "org": {"domain": "mybank.com", "name": "My Bank"},
          "id": "\(Self.externalAccountId)",
          "name": "Checking",
          "currency": "USD",
          "balance": "\(balance)",
          "balance-date": \(Self.daysAgo(0)),
          "transactions": [\(transactions)]
        }]}
        """
    }

    private func makeDatabase(seedTransactions: Bool = false) throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    type TEXT,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0,
                    sort_order REAL,
                    account_id TEXT,
                    account_sync_source TEXT,
                    bank TEXT,
                    balance_current INTEGER,
                    balance_available INTEGER,
                    balance_limit INTEGER
                )
            """)
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
                    schedule TEXT,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    parent_id TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE payees (
                    id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: "CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT)")
            try db.execute(sql: """
                CREATE TABLE banks (
                    id TEXT PRIMARY KEY, bank_id TEXT, name TEXT, tombstone INTEGER DEFAULT 0
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
            try db.execute(sql: """
                INSERT INTO accounts (id, name, type, offbudget, closed, tombstone, sort_order,
                                      account_id, account_sync_source)
                VALUES (?, 'Checking', 'checking', 0, 0, 0, 1, ?, 'simpleFin')
                """, arguments: [Self.accountId, Self.externalAccountId])
            if seedTransactions {
                try db.execute(sql: """
                    INSERT INTO transactions (id, acct, date, amount, cleared, tombstone, sort_order)
                    VALUES ('tx-manual', ?, ?, -3345, 0, 0, 1)
                    """, arguments: [Self.accountId, Self.expectedDay(6)])
            }
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func makeStore(database: BudgetDatabase, responseBody: String) async throws -> BudgetStore {
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)
        store.setSimpleFINClientForTesting(
            SimpleFINClient(session: BridgeTransport.makeSession(body: responseBody))
        )
        await store.loadBankSyncAccounts()
        return store
    }

    private func rows(path: URL, where clause: String = "1=1") throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM transactions WHERE \(clause) ORDER BY date, amount")
        }
    }

    private func withStoredAccessKey<T>(_ body: () async throws -> T) async throws -> T {
        try SimpleFINCredentials.save(
            SimpleFINAccessKey.parse("https://demo:demo@bridge.example.com/simplefin")
        )
        defer { try? SimpleFINCredentials.clear() }
        return try await body()
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Tests

    @Test func linkedAccountsAreDiscoveredFromTheBudgetFile() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, responseBody: accountSet(transactions: ""))

        #expect(store.bankSyncAccounts.count == 1)
        let linked = try #require(store.bankSyncAccounts.first)
        #expect(linked.id == Self.accountId)
        #expect(linked.externalAccountId == Self.externalAccountId)
        #expect(linked.source == .simpleFin)
    }

    @Test func firstSyncImportsTransactionsAndAnOpeningBalance() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, responseBody: accountSet(transactions: """
            {"id": "sf-1", "posted": \(Self.daysAgo(5)), "amount": "-33.45",
             "payee": "Blue Bottle", "description": "BLUE BOTTLE COFFEE"},
            {"id": "sf-2", "posted": 0, "pending": true, "transacted_at": \(Self.daysAgo(1)),
             "amount": "-12.00", "description": "Corner Store"}
            """))

        let result = try await withStoredAccessKey {
            try await store.syncBankAccounts()
        }

        #expect(result.added == 2)
        #expect(result.updated == 0)
        #expect(result.accountsSynced == 1)
        #expect(result.problems.isEmpty)

        let imported = try rows(path: url, where: "financial_id IS NOT NULL")
        #expect(imported.count == 2)
        #expect(imported[0]["financial_id"] == "sf-1")
        #expect(imported[1]["financial_id"] == "sf-2")
        #expect(imported[0]["amount"] == -3345)
        #expect(imported[0]["date"] == Self.expectedDay(5))
        #expect(imported[0]["cleared"] == 1)
        #expect(imported[0]["imported_description"] == "Blue Bottle")
        #expect(imported[0]["notes"] == "BLUE BOTTLE COFFEE")
        // Pending transactions import uncleared, dated when they happened.
        #expect(imported[1]["cleared"] == 0)
        #expect(imported[1]["date"] == Self.expectedDay(1))
        // With no payee of its own, the description names the payee.
        #expect(imported[1]["imported_description"] == "Corner Store")

        // The balance SimpleFIN reports is current, so what the account opened
        // with is that balance less everything just imported: 10000 - -4545.
        let opening = try rows(path: url, where: "starting_balance_flag = 1")
        #expect(opening.count == 1)
        #expect(opening[0]["amount"] == 14545)
        #expect(opening[0]["date"] == Self.expectedDay(5))
    }

    @Test func syncingAgainImportsNothingTwice() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let body = accountSet(transactions: """
            {"id": "sf-1", "posted": \(Self.daysAgo(5)), "amount": "-33.45", "payee": "Blue Bottle"}
            """)
        let store = try await makeStore(database: database, responseBody: body)

        let first = try await withStoredAccessKey { try await store.syncBankAccounts() }
        let second = try await withStoredAccessKey { try await store.syncBankAccounts() }

        #expect(first.added == 1)
        #expect(second.added == 0)
        #expect(second.updated == 0)
        #expect(try rows(path: url, where: "financial_id = 'sf-1'").count == 1)
    }

    /// A transaction entered by hand before the bank posted it should be
    /// adopted, not duplicated.
    @Test func aMatchingLocalTransactionIsAdoptedRatherThanDuplicated() async throws {
        let (database, url) = try makeDatabase(seedTransactions: true)
        defer { cleanup(url) }
        let store = try await makeStore(database: database, responseBody: accountSet(transactions: """
            {"id": "sf-1", "posted": \(Self.daysAgo(5)), "amount": "-33.45", "payee": "Blue Bottle"}
            """))

        let result = try await withStoredAccessKey { try await store.syncBankAccounts() }

        #expect(result.added == 0)
        #expect(result.updated == 1)

        let all = try rows(path: url, where: "acct = '\(Self.accountId)' AND starting_balance_flag = 0")
        #expect(all.count == 1)
        #expect(all[0]["id"] == "tx-manual")
        #expect(all[0]["financial_id"] == "sf-1")
        #expect(all[0]["cleared"] == 1)

        // An account that already had history takes no opening balance.
        #expect(try rows(path: url, where: "starting_balance_flag = 1").isEmpty)
    }

    @Test func importedTransactionsGenerateCRDTMessages() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, responseBody: accountSet(transactions: """
            {"id": "sf-1", "posted": \(Self.daysAgo(5)), "amount": "-33.45", "payee": "Blue Bottle"}
            """))

        _ = try await withStoredAccessKey { try await store.syncBankAccounts() }

        let queue = try DatabaseQueue(path: url.path)
        let financialIdMessages = try await queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messages_crdt
                WHERE dataset = 'transactions' AND column = 'financial_id'
                """) ?? 0
        }
        #expect(financialIdMessages == 1)
    }

    @Test func syncingWithoutAnAccessKeyIsRefused() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, responseBody: accountSet(transactions: ""))
        try? SimpleFINCredentials.clear()

        await #expect(throws: BudgetStoreError.bankSyncNotConfigured) {
            _ = try await store.syncBankAccounts()
        }
    }

    @Test func anAccountTheBridgeDoesntReturnIsReportedNotSilentlySkipped() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(
            database: database, responseBody: #"{"errors": [], "accounts": []}"#
        )

        let result = try await withStoredAccessKey { try await store.syncBankAccounts() }

        #expect(result.accountsSynced == 0)
        #expect(result.problems.count == 1)
        #expect(result.problems[0].contains("Checking"))
    }

    @Test func bridgeErrorsAreCarriedIntoTheResult() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let body = """
        {"errors": ["Connection to My Bank may need attention"], "accounts": [{
          "org": {"domain": "mybank.com", "name": "My Bank"},
          "id": "\(Self.externalAccountId)", "name": "Checking",
          "balance": "0.00", "transactions": []
        }]}
        """
        let store = try await makeStore(database: database, responseBody: body)

        let result = try await withStoredAccessKey { try await store.syncBankAccounts() }

        // The bridge's errors aren't keyed by account, so they're paired up by
        // the institution they name — which is what lets the account carry the
        // status the web UI reads.
        #expect(result.problems == ["Checking: Connection to My Bank may need attention"])
        #expect(result.summary.contains("Connection to My Bank may need attention"))

        let queue = try DatabaseQueue(path: url.path)
        let account = try #require(try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [Self.accountId])
        })
        #expect(account["bank_sync_status"] == "attention-required")
    }

    // MARK: - Linking

    @Test func linkingWritesTheColumnsTheWebUIReads() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, responseBody: accountSet(transactions: ""))
        let remote = try JSONDecoder().decode(SimpleFINAccount.self, from: Data("""
            {"org": {"domain": "mybank.com", "name": "My Bank"}, "id": "sf-acct-9",
             "name": "Savings", "balance": "0.00"}
            """.utf8))

        try await store.linkBankAccount(accountId: Self.accountId, to: remote)

        let queue = try DatabaseQueue(path: url.path)
        let account = try #require(try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [Self.accountId])
        })
        #expect(account["account_id"] == "sf-acct-9")
        #expect(account["account_sync_source"] == "simpleFin")
        let bankRowId: String? = account["bank"]
        #expect(bankRowId != nil)

        let bank = try #require(try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM banks WHERE id = ?", arguments: [bankRowId])
        })
        #expect(bank["bank_id"] == "mybank.com")
        #expect(bank["name"] == "My Bank")
    }

    @Test func unlinkingClearsTheColumnsAndLeavesTransactionsBehind() async throws {
        let (database, url) = try makeDatabase(seedTransactions: true)
        defer { cleanup(url) }
        let store = try await makeStore(database: database, responseBody: accountSet(transactions: ""))

        try await store.unlinkBankAccount(accountId: Self.accountId)

        let queue = try DatabaseQueue(path: url.path)
        let account = try #require(try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [Self.accountId])
        })
        let externalId: String? = account["account_id"]
        let source: String? = account["account_sync_source"]
        let bank: String? = account["bank"]
        let status: String? = account["bank_sync_status"]
        let cachedBalance: Int? = account["balance_current"]
        #expect(externalId == nil)
        #expect(source == nil)
        #expect(bank == nil)
        // A left-behind status would keep showing an error badge in the web UI
        // for an account that no longer syncs at all.
        #expect(status == nil)
        #expect(cachedBalance == nil)
        #expect(try rows(path: url).count == 1)
    }
    
    @Test func aSyncStampsLastSyncAndStatusForTheWebUI() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, responseBody: accountSet(transactions: """
            {"id": "sf-1", "posted": \(Self.daysAgo(5)), "amount": "-33.45", "payee": "Blue Bottle"}
            """))

        _ = try await withStoredAccessKey { try await store.syncBankAccounts() }

        let queue = try DatabaseQueue(path: url.path)
        let account = try #require(try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [Self.accountId])
        })
        #expect(account["bank_sync_status"] == "ok")
        let lastSync: String? = account["last_sync"]
        // Milliseconds since the epoch as a string, the way every other client
        // writes it.
        #expect((Int64(lastSync ?? "") ?? 0) > 1_700_000_000_000)
    }

    /// A `YYYY-MM-DD` string the sync window will accept, however long this
    /// test lives.
    private static func isoDaysAgo(_ days: Int) -> String {
        BankSyncReconciler.isoString(
            from: BankSyncReconciler.day(Transaction.yyyymmdd(from: Date()), offsetBy: -days)
        )
    }

    private func makeServerStore(
        database: BudgetDatabase,
        bodies: [String: String]
    ) async throws -> BudgetStore {
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)

        let serverClient = ActualServerClient(session: ServerTransport.makeSession(bodies))
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("session-token")
        store.setServerClientForTesting(serverClient)

        // Deliberately not given a SimpleFIN client or a stored access key:
        // anything that reaches the bridge directly would fail the test.
        await store.loadBankSyncAccounts()
        return store
    }

    // MARK: - Through the server

    /// The point of the whole arrangement: a server that already has SimpleFIN
    /// needs no second setup token here.
    @Test func syncsThroughTheServerWithNoDeviceKey() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeServerStore(database: database, bodies: [
            "/simplefin/status": #"{"status":"ok","data":{"configured":true}}"#,
            "/simplefin/transactions": """
            {"status":"ok","data":{"\(Self.externalAccountId)":{
              "startingBalance": 10000,
              "transactions": {"all": [
                {"transactionId": "sf-1", "date": "\(Self.isoDaysAgo(5))",
                 "payeeName": "Blue Bottle", "notes": "BLUE BOTTLE COFFEE", "booked": true,
                 "transactionAmount": {"amount": "-33.45", "currency": "USD"}}
              ]}}}}
            """
        ])

        let result = try await store.syncBankAccounts()

        #expect(result.added == 1)
        #expect(result.accountsSynced == 1)
        #expect(result.problems.isEmpty)
        #expect(store.serverProvidesBankSync)
        #expect(ServerTransport.requestedPaths.contains("/simplefin/transactions"))

        let queue = try DatabaseQueue(path: url.path)
        let imported = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM transactions WHERE financial_id = 'sf-1'")
        }
        #expect(imported.count == 1)
        #expect(imported[0]["amount"] == -3345)
        #expect(imported[0]["cleared"] == 1)
    }

    /// A server without its own connection, and no key here either, is the one
    /// case where there's genuinely nothing to sync with.
    @Test func refusesWhenNeitherTheServerNorTheDeviceHasAConnection() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeServerStore(database: database, bodies: [
            "/simplefin/status": #"{"status":"ok","data":{"configured":false}}"#
        ])
        try? SimpleFINCredentials.clear()

        await #expect(throws: BudgetStoreError.bankSyncNotConfigured) {
            _ = try await store.syncBankAccounts()
        }
        #expect(!store.serverProvidesBankSync)
    }

    /// An Actual release that predates the routes 404s them, which must read as
    /// "this server can't do bank sync" rather than as a failure.
    @Test func treatsAMissingRouteAsNoServerConnection() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeServerStore(database: database, bodies: [:])
        try? SimpleFINCredentials.clear()

        await #expect(throws: BudgetStoreError.bankSyncNotConfigured) {
            _ = try await store.syncBankAccounts()
        }
    }

    @Test func reportsAnAccountTheServerCouldntFetch() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeServerStore(database: database, bodies: [
            "/simplefin/status": #"{"status":"ok","data":{"configured":true}}"#,
            "/simplefin/transactions": """
            {"status":"ok","data":{"errors":{"\(Self.externalAccountId)":[
              {"error_type":"ACCOUNT_NEEDS_ATTENTION","error_code":"ACCOUNT_NEEDS_ATTENTION",
               "reason":"The account needs your attention at SimpleFIN."}
            ]}}}
            """
        ])

        let result = try await store.syncBankAccounts()

        #expect(result.problems.count == 1)
        #expect(result.problems[0].contains("needs your attention"))

        // The status the web UI reads comes across too.
        let queue = try DatabaseQueue(path: url.path)
        let account = try #require(try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [Self.accountId])
        })
        #expect(account["bank_sync_status"] == "attention-required")
    }

    @Test func aRejectedServerKeyIsReportedNotSwallowed() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeServerStore(database: database, bodies: [
            "/simplefin/status": #"{"status":"ok","data":{"configured":true}}"#,
            "/simplefin/transactions": """
            {"status":"ok","data":{"error_type":"INVALID_ACCESS_TOKEN",
             "error_code":"INVALID_ACCESS_TOKEN","status":"rejected",
             "reason":"Invalid SimpleFIN access token."}}
            """
        ])

        let result = try await store.syncBankAccounts()

        #expect(result.accountsSynced == 0)
        #expect(result.problems.contains { $0.contains("Invalid SimpleFIN access token.") })
    }

    @Test func linkingScreenListsTheServersAccounts() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeServerStore(database: database, bodies: [
            "/simplefin/status": #"{"status":"ok","data":{"configured":true}}"#,
            "/simplefin/accounts": """
            {"status":"ok","data":{"accounts":[
              {"org":{"domain":"mybank.com","name":"My Bank"},"id":"sf-acct-1",
               "name":"Checking","balance":"100.00"}
            ]}}
            """
        ])

        let accounts = try await store.fetchBankAccounts()

        #expect(accounts.count == 1)
        #expect(accounts[0].id == "sf-acct-1")
        #expect(accounts[0].org.bankId == "mybank.com")
        #expect(accounts[0].balanceCents == 10000)
    }
}
