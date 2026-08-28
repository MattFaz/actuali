import Foundation
import GRDB
import Testing
@testable import Actuali

/// A canned Wallet, standing in for FinanceKit off-device.
private struct StubWalletStore: AppleWalletReading {
    var availabilityValue: AppleWalletAvailability = .authorized
    var accountsValue: [AppleWalletAccount] = []
    var transactionsByAccount: [String: [AppleWalletTransaction]] = [:]

    func availability() async -> AppleWalletAvailability { availabilityValue }
    func requestAccess() async throws -> Bool { availabilityValue == .authorized }
    func accounts() async throws -> [AppleWalletAccount] { accountsValue }
    func transactions(accountId: String) async throws -> [AppleWalletTransaction] {
        transactionsByAccount[accountId] ?? []
    }
}

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

    private func makeDatabase(linked: Bool = true) throws -> (BudgetDatabase, URL) {
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
            if linked {
                try db.execute(sql: """
                    INSERT INTO accounts (id, name, type, offbudget, closed, tombstone, sort_order,
                                          account_id, account_sync_source)
                    VALUES (?, 'Apple Card', 'credit', 0, 0, 0, 1, ?, 'financeKit')
                    """, arguments: [Self.accountId, Self.externalAccountId])
            } else {
                try db.execute(sql: """
                    INSERT INTO accounts (id, name, type, offbudget, closed, tombstone, sort_order)
                    VALUES (?, 'Apple Card', 'credit', 0, 0, 0, 1)
                    """, arguments: [Self.accountId])
            }
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func makeStore(
        database: BudgetDatabase,
        walletStore: any AppleWalletReading
    ) async throws -> BudgetStore {
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)
        store.setAppleWalletStoreForTesting(walletStore)
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

        // The card owes $500 now, so what it opened with is that less the
        // imported history: -50000 - -4545.
        let opening = try rows(path: url, where: "starting_balance_flag = 1")
        #expect(opening.count == 1)
        #expect(opening[0]["amount"] == -45455)

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

    @Test func linkingWritesTheColumnsTheWebUIReads() async throws {
        let (database, url) = try makeDatabase(linked: false)
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard())
        let remote = try #require(try await store.fetchAppleWalletAccounts().first)

        try await store.linkBankAccount(accountId: Self.accountId, to: remote.remoteAccount)

        let account = try #require(
            try row(path: url, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [Self.accountId])
        )
        #expect(account["account_id"] == Self.externalAccountId)
        #expect(account["account_sync_source"] == "financeKit")
        let bankRowId: String? = account["bank"]
        #expect(bankRowId != nil)

        let bank = try #require(
            try row(path: url, sql: "SELECT * FROM banks WHERE id = ?", arguments: [bankRowId])
        )
        #expect(bank["bank_id"] == "Apple")
        #expect(bank["name"] == "Apple")
    }

    /// A Wallet link made on another device (or before an iPad restore) can't
    /// be serviced where FinanceKit has nothing — that's a quiet skip, not an
    /// error on every sync.
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

    @Test func anAccountThisWalletDoesntHaveIsReportedNotSilentlySkipped() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        var wallet = appleCard()
        wallet.accountsValue = []
        let store = try await makeStore(database: database, walletStore: wallet)

        let result = try await store.syncBankAccounts()

        #expect(result.accountsSynced == 0)
        #expect(result.problems.count == 1)
        #expect(result.problems[0].contains("Apple Card"))
        #expect(result.problems[0].contains("Wallet"))

        let account = try #require(
            try row(path: url, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [Self.accountId])
        )
        #expect(account["bank_sync_status"] == "account-missing")
    }
}
