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
            // Every display read joins through these; a backfill fetches the
            // opening balance back to correct it, so this fixture needs them.
            try db.execute(sql: """
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY, name TEXT, cat_group TEXT,
                    is_income INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: "CREATE TABLE category_mapping (id TEXT PRIMARY KEY, transferId TEXT)")
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

    /// What the account is worth: every live row, opening balance included.
    /// A bank-linked account reconciles when this equals what the bank says.
    private func accountBalance(path: URL) throws -> Int {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(amount), 0) FROM transactions
                WHERE acct = ? AND (tombstone = 0 OR tombstone IS NULL)
                """, arguments: [Self.accountId]) ?? 0
        }
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Tests

    /// Budget load, foregrounding and pull-to-refresh import Wallet feeds
    /// without a button press — and without popping the sync summary alert.
    @Test func autoSyncImportsQuietly() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard())

        await store.autoSyncAppleWalletAccounts()

        #expect(try rows(path: url, where: "financial_id IS NOT NULL").count == 2)
        #expect(store.bankSyncSummary == nil)
    }

    @Test func pullToRefreshImportsWalletTransactions() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard())

        await store.sync()

        #expect(try rows(path: url, where: "financial_id IS NOT NULL").count == 2)
    }

    @Test func foregroundSyncImportsWalletTransactions() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard())

        await store.syncOnForeground()

        #expect(try rows(path: url, where: "financial_id IS NOT NULL").count == 2)
    }

    @Test func backgroundSyncImportsWalletTransactions() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard())

        #expect(await store.syncInBackground())

        #expect(try rows(path: url, where: "financial_id IS NOT NULL").count == 2)
    }

    // MARK: - Import start day

    /// With no chosen day, imports reach back to the day the budget file
    /// began — the day of its earliest CRDT message, which travels with the
    /// file to every device.
    @Test func importStartDefaultsToTheDayTheBudgetBegan() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO messages_crdt (timestamp, dataset, row, column, value)
                VALUES ('2024-03-05T12:00:00.000Z-0000-abcdef1234567890',
                        'accounts', 'acct-card', 'name', X'00')
                """)
        }
        let store = try await makeStore(
            database: database, walletStore: appleCard(), linked: false
        )

        #expect(await store.resolvedBankSyncImportStartDay() == 20240305)
    }

    /// A budget with no messages yet falls back to the shared 90-day lookback.
    @Test func importStartFallsBackToTheLookbackWindow() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(
            database: database, walletStore: appleCard(), linked: false
        )

        let resolved = await store.resolvedBankSyncImportStartDay()
        #expect(resolved == DayDate.today().adding(days: -89).yyyymmdd)
    }

    /// The chosen day bounds the first import: anything older stays out, and
    /// what it did to the balance lands in the opening balance instead.
    @Test func aChosenDayLimitsTheFirstImport() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard())
        await store.setBankSyncImportStartDay(Self.expectedDay(2))

        let result = try await store.syncBankAccounts()

        // Only the day-1 pending purchase is in the window; the day-5 booked
        // one stays out.
        let imported = try rows(path: url, where: "financial_id IS NOT NULL")
        #expect(imported.count == 1)
        #expect(imported[0]["financial_id"] == "33333333-3333-3333-3333-333333333333")
        #expect(result.accountsSynced == 1)
        // What stayed out is still in the balance, via the opening.
        #expect(try accountBalance(path: url) == -51200)
    }

    /// Moving the day earlier reaches past the account's existing history and
    /// pulls the older transactions in — on the next ordinary sync, with no
    /// special "backfill" call.
    @Test func movingTheDayEarlierReachesPastExistingHistory() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard())
        await store.setBankSyncImportStartDay(Self.expectedDay(2))
        _ = try await store.syncBankAccounts()
        #expect(try rows(path: url, where: "financial_id IS NOT NULL").count == 1)

        await store.setBankSyncImportStartDay(Self.expectedDay(30))
        let backfill = try await store.syncBankAccounts()

        #expect(backfill.added == 1)
        let imported = try rows(path: url, where: "financial_id IS NOT NULL")
        #expect(imported.count == 2)
        #expect(imported[0]["financial_id"] == "11111111-1111-1111-1111-111111111111")
    }

    /// A backfill adds detail, not money. The opening balance already stood in
    /// for everything before the account's first imported day, so giving those
    /// rows their own lines must leave the account reconciling exactly as it
    /// did — otherwise it drifts from the card by the backfilled amount.
    @Test func aBackfillLeavesTheAccountBalanceAlone() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard())
        await store.setBankSyncImportStartDay(Self.expectedDay(2))
        _ = try await store.syncBankAccounts()
        #expect(try accountBalance(path: url) == -51200)

        await store.setBankSyncImportStartDay(Self.expectedDay(30))
        _ = try await store.syncBankAccounts()

        #expect(try accountBalance(path: url) == -51200)
        // The opening gave back exactly what the backfilled row carries…
        let opening = try rows(path: url, where: "starting_balance_flag = 1")
        #expect(opening.count == 1)
        #expect(opening[0]["amount"] == -46655)
        // …and moved back to sit at or before the history it opens.
        #expect(opening[0]["date"] == Self.expectedDay(5))
    }

    /// The chosen day is a debt the store keeps until some sync pays it. A run
    /// that never happens — dropped because another sync was in flight, failed,
    /// or killed — must not strand the setting: the next sync still reaches it.
    @Test func anUnhonouredBackfillIsHeldForTheNextSync() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard())
        await store.setBankSyncImportStartDay(Self.expectedDay(2))
        _ = try await store.syncBankAccounts()
        #expect(try rows(path: url, where: "financial_id IS NOT NULL").count == 1)

        // Choose an earlier day and run nothing at all, the way a dropped tap
        // leaves it. A later automatic pass is what picks the debt up.
        await store.setBankSyncImportStartDay(Self.expectedDay(30))
        await store.autoSyncAppleWalletAccounts()

        #expect(try rows(path: url, where: "financial_id IS NOT NULL").count == 2)
        #expect(try accountBalance(path: url) == -51200)
    }

    /// Once the reach has landed, ordinary syncs stop asking for it — and
    /// nothing is imported or removed twice.
    @Test func aPaidBackfillDoesNotRepeat() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard())
        await store.setBankSyncImportStartDay(Self.expectedDay(30))
        _ = try await store.syncBankAccounts()

        let again = try await store.syncBankAccounts()

        #expect(again.added == 0)
        #expect(again.updated == 0)
        #expect(try rows(path: url, where: "financial_id IS NOT NULL").count == 2)
        #expect(try rows(path: url, where: "starting_balance_flag = 1").count == 1)
    }

    /// Moving the day later removes nothing — the footer promises it.
    @Test func movingTheDayLaterKeepsWhatWasImported() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard())
        await store.setBankSyncImportStartDay(Self.expectedDay(30))
        _ = try await store.syncBankAccounts()
        #expect(try rows(path: url, where: "financial_id IS NOT NULL").count == 2)

        await store.setBankSyncImportStartDay(Self.expectedDay(2))
        _ = try await store.syncBankAccounts()

        #expect(try rows(path: url, where: "financial_id IS NOT NULL").count == 2)
        #expect(try accountBalance(path: url) == -51200)
    }

    /// What a run inserts comes back on the result, so the automatic sync
    /// can post the new-transaction notification — the detector path only
    /// sees rows authored by other devices, which these are not. The opening
    /// balance stays out; nobody needs a banner for it.
    @Test func theResultCarriesInsertedRowsForNotification() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, walletStore: appleCard())

        let result = try await store.syncBankAccounts()
        #expect(result.importedTransactions.count == 2)
        #expect(result.importedTransactions.allSatisfy { $0.accountId == Self.accountId })

        let second = try await store.syncBankAccounts()
        #expect(second.importedTransactions.isEmpty)
    }

    /// Early builds wrote financeKit links into the synced columns. Loading
    /// adopts them into the device-local store and clears the columns like an
    /// unlink would — the link itself must survive the move.
    @Test func strayColumnLinksMigrateToTheDeviceLocalStore() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let queue = try DatabaseQueue(path: url.path)
        let accountId = Self.accountId
        let externalId = Self.externalAccountId
        try await queue.write { db in
            try db.execute(sql: """
                UPDATE accounts
                SET account_id = ?, account_sync_source = 'financeKit', bank = 'bank-1'
                WHERE id = ?
                """, arguments: [externalId, accountId])
        }
        let store = try await makeStore(
            database: database, walletStore: appleCard(), linked: false
        )

        // The link survives, served from the device-local store…
        let link = try #require(store.bankSyncAccount(forAccountId: accountId))
        #expect(link.source == .financeKit)
        #expect(link.externalAccountId == externalId)

        // …the synced columns are cleared the way any unlink clears them…
        let account = try #require(
            try row(path: url, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [accountId])
        )
        let source: String? = account["account_sync_source"]
        let externalColumn: String? = account["account_id"]
        let bank: String? = account["bank"]
        #expect(source == nil)
        #expect(externalColumn == nil)
        #expect(bank == nil)

        // …and the account still syncs.
        let result = try await store.syncBankAccounts()
        #expect(result.accountsSynced == 1)
    }

    /// A device that can't serve the feed skips the automatic pass entirely —
    /// no import, and no alert nobody asked for.
    @Test func autoSyncStaysQuietWhenWalletCantAnswer() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        var wallet = appleCard()
        wallet.availabilityValue = .denied
        let store = try await makeStore(database: database, walletStore: wallet)

        await store.autoSyncAppleWalletAccounts()

        #expect(try rows(path: url, where: "financial_id IS NOT NULL").isEmpty)
        #expect(store.bankSyncSummary == nil)
    }

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
