import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct PendingImportApproverTests {

    private func makeStore() -> BudgetStore {
        let store = BudgetStore.previewInstance()
        // Unique per test: `defaultAccountId` is UserDefaults keyed by budget id,
        // and these tests run in parallel — a shared id lets one test's default
        // account bleed into another's resolution.
        store.currentBudgetId = "test-budget-\(UUID().uuidString)"
        return store
    }

    /// Non-async so GRDB's `write` resolves to its synchronous overload.
    private func makeDatabaseFile() throws -> (BudgetDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY, starting_balance_flag INTEGER DEFAULT 0,
                    isParent INTEGER DEFAULT 0, isChild INTEGER DEFAULT 0,
                    acct TEXT, category TEXT, amount INTEGER, description TEXT,
                    notes TEXT, date INTEGER, imported_description TEXT,
                    financial_id TEXT, transferred_id TEXT, sort_order REAL,
                    tombstone INTEGER DEFAULT 0, cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0, parent_id TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT,
                    transfer_acct TEXT, tombstone INTEGER DEFAULT 0)
                """)
            try db.execute(sql: "CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT)")
            try db.execute(sql: """
                CREATE TABLE messages_crdt (id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE, dataset TEXT NOT NULL,
                    row TEXT NOT NULL, column TEXT NOT NULL, value BLOB NOT NULL)
                """)
        }
        return (try BudgetDatabase(path: url), url)
    }

    /// A store with a real (temp-file) budget database wired, so the approve
    /// success path can write and the resulting signed amount can be checked.
    private func makeWritableStore() async throws -> (BudgetStore, URL) {
        let (database, url) = try makeDatabaseFile()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")

        let store = makeStore()
        store.configureForTesting(database: database, syncClient: syncClient)
        return (store, url)
    }

    private func account(_ id: String, _ name: String, closed: Bool = false) -> Account {
        Account(id: id, name: name, type: .checking, offBudget: false, closed: closed,
                sortOrder: 0, balance: 0)
    }

    @Test func refusesInvalidAmount() async {
        let store = makeStore()
        let approver = PendingImportApprover(store: store)

        let nilAmountItem = PendingImport(amount: nil, payee: "Test", rawText: "test")
        await #expect(throws: PendingImportApprover.ApproveError.invalidAmount) {
            try await approver.approve(nilAmountItem)
        }

        let zeroAmountItem = PendingImport(amount: 0, payee: "Test", rawText: "test")
        await #expect(throws: PendingImportApprover.ApproveError.invalidAmount) {
            try await approver.approve(zeroAmountItem)
        }

        let negativeAmountItem = PendingImport(amount: -15.0, payee: "Test", rawText: "test")
        await #expect(throws: PendingImportApprover.ApproveError.invalidAmount) {
            try await approver.approve(negativeAmountItem)
        }
    }

    @Test func refusesWhenNoAccountAvailable() async {
        let store = makeStore()
        store.accounts = []
        store.defaultAccountId = nil

        let approver = PendingImportApprover(store: store)
        let item = PendingImport(amount: 25.0, payee: "Coffee", cardHint: "nonexistent", rawText: "msg")

        await #expect(throws: PendingImportApprover.ApproveError.noAccountAvailable) {
            try await approver.approve(item)
        }
    }

    @Test func refusesWhenTargetAccountIsClosed() async {
        let store = makeStore()
        let closedAcct = account("acct_closed", "Closed Account", closed: true)
        store.accounts = [closedAcct]
        store.defaultAccountId = closedAcct.id

        let approver = PendingImportApprover(store: store)
        let item = PendingImport(amount: 25.0, payee: "Coffee", rawText: "msg")

        await #expect(throws: PendingImportApprover.ApproveError.accountClosed) {
            try await approver.approve(item)
        }
    }

    @Test func logsExpenseAsNegativeAndRoutesByCardHint() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]

        let approver = PendingImportApprover(store: store)
        // cardHint matches the account name, so resolution uses the hint route,
        // not the default account.
        let item = PendingImport(amount: 18.50, payee: "Starbucks", cardHint: "Checking",
                                 isIncome: false, rawText: "msg")

        let result = try await approver.approve(item)

        #expect(result.transaction.accountId == "acct_checking")
        #expect(result.transaction.amount == -1850)
    }

    @Test func logsIncomeAsPositiveViaDefaultAccount() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        store.defaultAccountId = "acct_checking"

        let approver = PendingImportApprover(store: store)
        let item = PendingImport(amount: 25.0, payee: "Employer", isIncome: true, rawText: "msg")

        let result = try await approver.approve(item)

        #expect(result.transaction.accountId == "acct_checking")
        #expect(result.transaction.amount == 2500)
    }
}
