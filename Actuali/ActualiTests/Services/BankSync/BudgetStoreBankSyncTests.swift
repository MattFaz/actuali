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
                    bank TEXT
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

        #expect(result.problems == ["Connection to My Bank may need attention"])
        #expect(result.summary.contains("Connection to My Bank may need attention"))
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
        #expect(externalId == nil)
        #expect(source == nil)
        #expect(try rows(path: url).count == 1)
    }
}
