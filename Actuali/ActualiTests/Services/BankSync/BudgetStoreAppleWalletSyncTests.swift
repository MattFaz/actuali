import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
@Suite(.serialized)
struct BudgetStoreAppleWalletSyncTests {

    private static let accountId = "acct-card"
    /// FinanceKit account UUID, lowercased, the way linking stores it.
    private static let externalAccountId = "22222222-2222-2222-2222-222222222222"

    private static func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: Date())!
    }

    private static func expectedDay(_ days: Int) -> Int {
        Transaction.yyyymmdd(from: daysAgo(days))
    }

    /// An Apple Card with a booked purchase and a pending one, owing $500.
    private func appleCard() -> StubWalletStore {
        StubWalletStore(
            accountsValue: [AppleWalletAccount(
                id: Self.externalAccountId, name: "Apple Card",
                institutionName: "Apple", balanceCents: -50000
            )],
            transactionsByAccount: [Self.externalAccountId: [
                AppleWalletTransaction(
                    id: "11111111-1111-1111-1111-111111111111",
                    amount: Decimal(string: "33.45")!, isCredit: false,
                    merchantName: "Blue Bottle", description: "BLUE BOTTLE COFFEE",
                    status: .booked, date: Self.daysAgo(5)
                ),
                AppleWalletTransaction(
                    id: "33333333-3333-3333-3333-333333333333",
                    amount: Decimal(string: "12.00")!, isCredit: false,
                    merchantName: nil, description: "Corner Store",
                    status: .pending, date: Self.daysAgo(1)
                )
            ]]
        )
    }

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
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
                INSERT INTO accounts (id, name, type, offbudget, closed, tombstone, sort_order)
                VALUES (?, 'Apple Card', 'credit', 0, 0, 0, 1)
                """, arguments: [Self.accountId])
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func makeStore(
        database: BudgetDatabase,
        walletStore: any AppleWalletReading,
        linked: Bool = true
    ) async throws -> BudgetStore {
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)
        let defaults = try #require(UserDefaults(suiteName: "BudgetStoreAppleWalletSyncTests"))
        defaults.removePersistentDomain(forName: "BudgetStoreAppleWalletSyncTests")
        store.configureAppleWalletLinksForTesting(defaults: defaults, budgetId: "wallet-tests")
        store.setAppleWalletStoreForTesting(walletStore)
        if linked {
            let remote = AppleWalletAccount(
                id: Self.externalAccountId,
                name: "Apple Card",
                institutionName: "Apple",
                balanceCents: nil
            ).remoteAccount
            try await store.linkBankAccount(accountId: Self.accountId, to: remote)
        } else {
            await store.loadBankSyncAccounts()
        }
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

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Tests

    @Test func firstSyncImportsTransactionsAndACreditCardOpeningBalance() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard())

        let result = try await store.syncBankAccounts()

        // Two downloads plus the opening balance, which counts as an import
        // too (upstream folds its id into `added`).
        #expect(result.added == 3)
        #expect(result.updated == 0)
        #expect(result.accountsSynced == 1)
        #expect(result.problems.isEmpty)

        let imported = try rows(path: url, where: "financial_id IS NOT NULL")
        #expect(imported.count == 2)
        #expect(imported[0]["financial_id"] == "11111111-1111-1111-1111-111111111111")
        #expect(imported[0]["amount"] == -3345)
        #expect(imported[0]["date"] == Self.expectedDay(5))
        #expect(imported[0]["cleared"] == 1)
        #expect(imported[0]["imported_description"] == "Blue Bottle")
        #expect(imported[0]["notes"] == "BLUE BOTTLE COFFEE")
        // Pending transactions import uncleared, dated when they happened.
        #expect(imported[1]["cleared"] == 0)
        #expect(imported[1]["date"] == Self.expectedDay(1))
        #expect(imported[1]["imported_description"] == "Corner Store")

        // The booked balance excludes the pending $12, so the current balance
        // is -51200 and the opening balance is -51200 - -4545.
        let opening = try rows(path: url, where: "starting_balance_flag = 1")
        #expect(opening.count == 1)
        #expect(opening[0]["amount"] == -46655)

        // The same status columns a SimpleFIN sync stamps for the web UI.
        let account = try #require(
            try row(path: url, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [Self.accountId])
        )
        #expect(account["bank_sync_status"] == "ok")
    }

    @Test func syncingAgainImportsNothingTwice() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard())

        let first = try await store.syncBankAccounts()
        let second = try await store.syncBankAccounts()

        #expect(first.added == 3)
        #expect(second.added == 0)
        #expect(second.updated == 0)
        #expect(try rows(path: url, where: "financial_id IS NOT NULL").count == 2)
    }

    @Test func linkingStaysDeviceLocal() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard(), linked: false)
        let remote = try #require(try await store.fetchAppleWalletAccounts().first)

        try await store.linkBankAccount(accountId: Self.accountId, to: remote.remoteAccount)

        let account = try #require(
            try row(path: url, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [Self.accountId])
        )
        let externalId: String? = account["account_id"]
        let source: String? = account["account_sync_source"]
        let bankRowId: String? = account["bank"]
        #expect(externalId == nil)
        #expect(source == nil)
        #expect(bankRowId == nil)
        #expect(store.bankSyncAccount(forAccountId: Self.accountId)?.source == .financeKit)
        #expect(store.bankSyncAccount(forAccountId: Self.accountId)?.externalAccountId
                == Self.externalAccountId)
    }

    @Test func unlinkingRemovesTheDeviceLocalLink() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard())

        try await store.unlinkBankAccount(accountId: Self.accountId)

        #expect(store.bankSyncAccount(forAccountId: Self.accountId) == nil)
    }

    /// A device without FinanceKit can't service its local Wallet link. That
    /// is a quiet skip, not an error on every sync.
    @Test func anUnsupportedDeviceSkipsWalletAccountsQuietly() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        var wallet = appleCard()
        wallet.availabilityValue = .unsupported
        let store = try await makeStore(database: database, walletStore: wallet)

        let result = try await store.syncBankAccounts()

        #expect(result == BudgetStore.BankSyncResult())
        #expect(try rows(path: url, where: "financial_id IS NOT NULL").isEmpty)
    }

    /// Access someone turned off is theirs to turn back on — say so.
    @Test func deniedWalletAccessIsReported() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        var wallet = appleCard()
        wallet.availabilityValue = .denied
        let store = try await makeStore(database: database, walletStore: wallet)

        let result = try await store.syncBankAccounts()

        #expect(result.accountsSynced == 0)
        #expect(result.problems.count == 1)
        #expect(result.problems[0].contains("Wallet access"))
    }

    @Test func anAccountThisWalletDoesntHaveIsSkippedQuietly() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        var wallet = appleCard()
        wallet.accountsValue = []
        let store = try await makeStore(database: database, walletStore: wallet)

        let result = try await store.syncBankAccounts()

        #expect(result == BudgetStore.BankSyncResult())

        // Missing-from-Wallet is device-local state, so it must not stamp a
        // failure into the budget's synced status columns.
        let account = try #require(
            try row(path: url, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [Self.accountId])
        )
        let status: String? = account["bank_sync_status"]
        #expect(status == nil)
    }
}
