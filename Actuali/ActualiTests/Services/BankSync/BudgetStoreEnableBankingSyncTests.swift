import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actuali

/// What one stubbed session was asked for, in order.
private final class EnableBankingRequestLog: Sendable {
    struct Entry: Sendable {
        let path: String
        let body: Data
    }

    let entries = Mutex<[Entry]>([])

    func bodies(for path: String) -> [[String: Any]] {
        entries.withLock { $0 }
            .filter { $0.path == path }
            .compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
    }
}

@MainActor
struct BudgetStoreEnableBankingSyncTests {
    private static let ebAccountId = "acct-eb"
    private static let ebExternalId = "eb-uid-1"
    private static let sfAccountId = "acct-sf"
    private static let sfExternalId = "sf-acct-1"

    private static func isoDaysAgo(_ days: Int) -> String {
        DayDate.today().adding(days: -days).iso
    }

    private static func okBody(startingBalance: Int = 10000) -> String {
        """
        {"status":"ok","data":{
          "transactions":{"all":[
            {"transactionId":"eb-1","date":"\(isoDaysAgo(5))","payeeName":"Blue Bottle",
             "booked":true,"transactionAmount":{"amount":"-33.45"}}
          ]},
          "balances":[],
          "startingBalance":\(startingBalance)}}
        """
    }

    private static let simpleFinBody = """
    {"status":"ok","data":{"\(sfExternalId)":{
      "startingBalance": 10000,
      "transactions": {"all": [
        {"transactionId": "sf-1", "date": "\(isoDaysAgo(5))",
         "payeeName": "Corner Store", "booked": true,
         "transactionAmount": {"amount": "-12.00", "currency": "USD"}}
      ]}}}}
    """

    private static let simpleFinFailure = """
    {"status":"ok","data":{"error_type":"INVALID_ACCESS_TOKEN",
     "error_code":"INVALID_ACCESS_TOKEN","status":"rejected",
     "reason":"Invalid SimpleFIN access token."}}
    """

    /// A budget with an Enable Banking account (bank "ING") and, on request,
    /// a SimpleFIN one.
    private func makeDatabase(withSimpleFin: Bool = false) async throws -> (BudgetDatabase, URL) {
        var statements = TestSchema.core + [
            TestSchema.preferences, TestSchema.rules,
            "INSERT INTO banks (id, bank_id, name) VALUES ('bank-1', 'bank-1', 'ING')",
        ]
        statements.append("""
        INSERT INTO accounts (id, name, type, offbudget, closed, tombstone, sort_order,
                              account_id, account_sync_source, bank)
        VALUES ('\(Self.ebAccountId)', 'Savings', 'savings', 0, 0, 0, 1,
                '\(Self.ebExternalId)', 'enableBanking', 'bank-1')
        """)
        if withSimpleFin {
            statements.append("""
            INSERT INTO accounts (id, name, type, offbudget, closed, tombstone, sort_order,
                                  account_id, account_sync_source)
            VALUES ('\(Self.sfAccountId)', 'Checking', 'checking', 0, 0, 0, 2,
                    '\(Self.sfExternalId)', 'simpleFin')
            """)
        }
        return try await makeTestDatabase(statements)
    }

    private static func defaultsSuite(for url: URL) -> String {
        "BudgetStoreEnableBankingSyncTests-\(url.lastPathComponent)"
    }

    private func cleanup(_ url: URL) {
        UserDefaults(suiteName: Self.defaultsSuite(for: url))?
            .removePersistentDomain(forName: Self.defaultsSuite(for: url))
        try? FileManager.default.removeItem(at: url)
    }

    /// A store whose server answers by path; a path with no body is a 404.
    /// `unreachable` fails every request as a timeout instead.
    private func makeServerStore(
        database: BudgetDatabase,
        bodies: [String: String],
        log: EnableBankingRequestLog? = nil,
        unreachable: Bool = false
    ) async throws -> BudgetStore {
        let store = try await makeTestStore(database: database)
        // A budget id and private defaults, as `BudgetStoreBankSyncTests` gives
        // its stores: without an id `setBankSyncImportStartDay` does nothing,
        // and with the shared defaults it would leak into other suites.
        let defaults = try #require(UserDefaults(suiteName: Self.defaultsSuite(
            for: URL(fileURLWithPath: database.dbQueueForTesting.path)
        )))
        store.configureAppleWalletLinksForTesting(defaults: defaults, budgetId: "enable-banking-tests")
        store.setSimpleFINAccessKeyForTesting(nil)

        let serverClient = ActualServerClient(session: StubTransport.session { request in
            let path = request.url?.path ?? ""
            log?.entries.withLock { $0.append(.init(path: path, body: request.bodyData)) }
            if unreachable {
                throw URLError(.timedOut)
            }
            let body = bodies[path]
            return StubTransport.Response(status: body == nil ? 404 : 200, body: Data((body ?? "").utf8))
        })
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("session-token")
        store.setServerClientForTesting(serverClient)

        await store.loadBankSyncAccounts()
        return store
    }

    private func rows(path: URL, where clause: String = "1=1") throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM transactions WHERE \(clause) ORDER BY date, amount")
        }
    }

    /// Fetches a single row synchronously so the non-Sendable `Row` never
    /// crosses an async boundary (see AGENTS.md on GRDB `Row` isolation).
    private func row(path: URL, sql: String, arguments: StatementArguments = StatementArguments()) throws -> Row? {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchOne(db, sql: sql, arguments: arguments)
        }
    }

    private func accountRow(path: URL, id: String) throws -> Row? {
        try row(path: path, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [id])
    }

    // MARK: - Sync

    @Test func syncsAnEnableBankingAccountThroughItsOwnRoute() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let log = EnableBankingRequestLog()
        let store = try await makeServerStore(database: database, bodies: [
            "/enablebanking/transactions": Self.okBody(),
        ], log: log)

        let result = try await store.syncBankAccounts()

        #expect(result.accountsSynced == 1)
        #expect(result.problems.isEmpty)
        let requests = log.bodies(for: "/enablebanking/transactions")
        #expect(requests.count == 1)
        #expect(requests[0]["accountId"] as? String == Self.ebExternalId)
        #expect(requests[0]["startDate"] as? String != nil)
        #expect(requests[0]["aspspName"] as? String == "ING")
        #expect(requests[0]["importPending"] == nil)

        let imported = try rows(path: url, where: "financial_id = 'eb-1'")
        #expect(imported.count == 1)
        #expect(imported[0]["amount"] == -3345)
        #expect(imported[0]["cleared"] == 1)

        let account = try #require(try accountRow(path: url, id: Self.ebAccountId))
        #expect(account["bank_sync_status"] == "ok")
        #expect((account["last_sync"] as String?) != nil)
    }

    @Test func firstSyncOpensAtTheBalanceAndNeverAsksForMoreThanTheBanksWindow() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let log = EnableBankingRequestLog()
        let store = try await makeServerStore(database: database, bodies: [
            "/enablebanking/transactions": Self.okBody(startingBalance: 10000),
        ], log: log)
        store.setBankSyncImportStartDay(DayDate.today().adding(days: -200).yyyymmdd)

        _ = try await store.syncBankAccounts()

        // The balance is current, so the account opened with that balance less
        // everything imported: 10000 - -3345.
        let opening = try rows(path: url, where: "starting_balance_flag = 1")
        #expect(opening.count == 1)
        #expect(opening[0]["amount"] == 13345)

        let startDate = try #require(
            log.bodies(for: "/enablebanking/transactions").first?["startDate"] as? String
        )
        // ISO dates compare correctly as strings.
        #expect(startDate >= Self.isoDaysAgo(89))
    }

    @Test func aConsentThatExpiredMarksTheAccountForReauthorization() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeServerStore(database: database, bodies: [
            "/enablebanking/transactions": """
            {"status":"ok","data":{"error_type":"ITEM_ERROR","error_code":"ITEM_LOGIN_REQUIRED"}}
            """,
        ])

        let result = try await store.syncBankAccounts()

        let message = try #require(
            BankSyncAccount.attentionMessage(status: "reauth-required", source: .enableBanking)
        )
        #expect(result.problems.contains { $0.contains(message) })
        #expect(try rows(path: url, where: "financial_id IS NOT NULL").isEmpty)
        let account = try #require(try accountRow(path: url, id: Self.ebAccountId))
        #expect(account["bank_sync_status"] == "reauth-required")
    }

    // MARK: - Mixed sources

    @Test func simpleFinFailingDoesNotStopEnableBanking() async throws {
        let (database, url) = try await makeDatabase(withSimpleFin: true)
        defer { cleanup(url) }
        let store = try await makeServerStore(database: database, bodies: [
            "/simplefin/status": #"{"status":"ok","data":{"configured":true}}"#,
            "/simplefin/transactions": Self.simpleFinFailure,
            "/enablebanking/transactions": Self.okBody(),
        ])

        let result = try await store.syncBankAccounts()

        #expect(result.problems.contains { $0.contains("Invalid SimpleFIN access token.") })
        #expect(try rows(path: url, where: "financial_id = 'eb-1'").count == 1)
    }

    @Test func enableBankingFailingDoesNotStopSimpleFin() async throws {
        let (database, url) = try await makeDatabase(withSimpleFin: true)
        defer { cleanup(url) }
        // No /enablebanking route: the server answers 404.
        let store = try await makeServerStore(database: database, bodies: [
            "/simplefin/status": #"{"status":"ok","data":{"configured":true}}"#,
            "/simplefin/transactions": Self.simpleFinBody,
        ])

        let result = try await store.syncBankAccounts()

        #expect(try rows(path: url, where: "financial_id = 'sf-1'").count == 1)
        #expect(!result.problems.isEmpty)
        let account = try #require(try accountRow(path: url, id: Self.ebAccountId))
        #expect(account["bank_sync_status"] == "failed")
    }

    @Test func aServerWithoutTheRouteReportsThatItDoesntOfferEnableBanking() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeServerStore(database: database, bodies: [:])

        let result = try await store.syncBankAccounts()

        let message = String(
            localized: "Your Actual server doesn't offer Enable Banking. Update the server, then try again."
        )
        #expect(result.problems.contains { $0.contains(message) })
        #expect(try rows(path: url, where: "financial_id IS NOT NULL").isEmpty)
        let account = try #require(try accountRow(path: url, id: Self.ebAccountId))
        #expect(account["bank_sync_status"] == "failed")
    }

    @Test func anUnreachableServerIsAskedOnceNotOncePerAccount() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        try await DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: """
            INSERT INTO accounts (id, name, type, offbudget, closed, tombstone, sort_order,
                                  account_id, account_sync_source, bank)
            VALUES ('acct-eb-2', 'Current', 'checking', 0, 0, 0, 3, 'eb-uid-2', 'enableBanking', 'bank-1')
            """)
        }
        let log = EnableBankingRequestLog()
        let store = try await makeServerStore(database: database, bodies: [:], log: log, unreachable: true)

        let result = try await store.syncBankAccounts()

        #expect(log.bodies(for: "/enablebanking/transactions").count == 1)
        #expect(result.problems.count == 2)
        for id in [Self.ebAccountId, "acct-eb-2"] {
            let account = try #require(try accountRow(path: url, id: id))
            #expect(account["bank_sync_status"] == "failed")
        }
    }

    // MARK: - Messages and accounts

    @Test func attentionMessagesDependOnTheSource() {
        let enableBanking = BankSyncAccount.attentionMessage(status: "reauth-required", source: .enableBanking)
        let simpleFin = BankSyncAccount.attentionMessage(status: "reauth-required", source: .simpleFin)

        #expect(enableBanking != nil)
        #expect(simpleFin != nil)
        #expect(enableBanking != simpleFin)
        #expect(BankSyncAccount.attentionMessage(status: "not-configured", source: .enableBanking) != nil)
        #expect(BankSyncAccount.attentionMessage(status: "ok", source: .enableBanking) == nil)
    }

    @Test func linkedAccountsCarryTheirBanksName() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }

        let accounts = try await database.fetchBankSyncAccounts()

        #expect(accounts.map(\.institutionName) == ["ING"])
    }
}
