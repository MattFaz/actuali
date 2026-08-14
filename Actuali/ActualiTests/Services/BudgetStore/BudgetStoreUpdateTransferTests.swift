import Foundation
import GRDB
import Testing
@testable import Actuali

/// End-to-end coverage for editing an existing transfer through
/// `saveTransaction` → `updateTransfer` (GH #104): both legs follow the
/// form's amount/date/notes/cleared, re-targeting moves the partner leg and
/// remaps both transfer payees, and categories survive only on an on-budget
/// leg whose partner account is off-budget.
@MainActor
struct BudgetStoreUpdateTransferTests {

    /// Upstream schema for every table the transaction fetch joins
    /// (matches BudgetStoreSaveTransactionTests, plus accounts/categories
    /// because `fetchTransaction` resolves display names).
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
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
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    parent_id TEXT
                );

                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    offbudget INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE payees (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    transfer_acct TEXT,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE payee_mapping (
                    id TEXT PRIMARY KEY,
                    targetId TEXT
                );

                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
                );

                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                );

                INSERT INTO accounts (id, name, offbudget) VALUES
                    ('acct-checking',  'Checking',  0),
                    ('acct-savings',   'Savings',   0),
                    ('acct-brokerage', 'Brokerage', 1);

                -- One transfer payee per account, like Actual maintains.
                INSERT INTO payees (id, name, transfer_acct) VALUES
                    ('payee-checking',  NULL, 'acct-checking'),
                    ('payee-savings',   NULL, 'acct-savings'),
                    ('payee-brokerage', NULL, 'acct-brokerage');

                INSERT INTO payee_mapping (id, targetId) VALUES
                    ('payee-checking',  'payee-checking'),
                    ('payee-savings',   'payee-savings'),
                    ('payee-brokerage', 'payee-brokerage');
                """)
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    /// Store wired to a real database and sync client, with the accounts and
    /// transfer payees mirrored into the in-memory caches `updateTransfer`
    /// reads (`accounts` for the off-budget rule, `payees` for payee lookup).
    private func makeStore(database: BudgetDatabase) async throws -> BudgetStore {
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)
        store.accounts = [
            Account(id: "acct-checking", name: "Checking", type: .checking,
                    offBudget: false, closed: false, sortOrder: 0, balance: 0),
            Account(id: "acct-savings", name: "Savings", type: .savings,
                    offBudget: false, closed: false, sortOrder: 1, balance: 0),
            Account(id: "acct-brokerage", name: "Brokerage", type: .investment,
                    offBudget: true, closed: false, sortOrder: 2, balance: 0),
        ]
        store.payees = [
            Payee(id: "payee-checking", name: "", transferAccountId: "acct-checking", tombstone: false),
            Payee(id: "payee-savings", name: "", transferAccountId: "acct-savings", tombstone: false),
            Payee(id: "payee-brokerage", name: "", transferAccountId: "acct-brokerage", tombstone: false),
        ]
        return store
    }

    /// Seed both legs of a Checking → Savings transfer for $25.00.
    private func seedTransfer(into database: BudgetDatabase,
                              sourceCategoryId: String? = nil) throws -> (source: Transaction, target: Transaction) {
        let source = Transaction(
            id: "leg-out", accountId: "acct-checking", date: 20260610, amount: -2500,
            payeeId: "payee-savings", payeeName: nil, categoryId: sourceCategoryId,
            categoryName: nil, notes: nil, cleared: false, reconciled: false,
            transferId: "leg-in", isParent: false, parentId: nil, tombstone: false,
            sortOrder: 1000, importedPayee: nil)
        let target = Transaction(
            id: "leg-in", accountId: "acct-savings", date: 20260610, amount: 2500,
            payeeId: "payee-checking", payeeName: nil, categoryId: nil,
            categoryName: nil, notes: nil, cleared: false, reconciled: false,
            transferId: "leg-out", isParent: false, parentId: nil, tombstone: false,
            sortOrder: 1000, importedPayee: nil)
        try database.insertTransaction(source)
        try database.insertTransaction(target)
        return (source, target)
    }

    private func form(
        accountId: String = "acct-checking",
        amount: String = "25.00",
        transferToAccountId: String? = "acct-savings",
        categoryId: String? = nil,
        notes: String = "",
        cleared: Bool = false
    ) -> BudgetStore.TransactionForm {
        BudgetStore.TransactionForm(
            accountId: accountId,
            type: .transfer,
            amount: amount,
            payeeName: "",
            transferToAccountId: transferToAccountId,
            categoryId: categoryId,
            notes: notes,
            date: Transaction.date(fromYYYYMMDD: 20260715),
            cleared: cleared
        )
    }

    private func rows(path: URL) throws -> [String: Row] {
        let queue = try DatabaseQueue(path: path.path)
        let all = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM transactions")
        }
        return Dictionary(uniqueKeysWithValues: all.map { ($0["id"] as String, $0) })
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func editingATransferUpdatesBothLegs() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        let (source, _) = try seedTransfer(into: database)

        var edit = form(amount: "40.00", notes: "moved more")
        edit.cleared = true
        try await store.saveTransaction(edit, editing: source)

        let byId = try rows(path: path)
        let out = try #require(byId["leg-out"])
        let inn = try #require(byId["leg-in"])
        #expect(out["amount"] == -4000)
        #expect(inn["amount"] == 4000)
        #expect(out["date"] == 20260715)
        #expect(inn["date"] == 20260715)
        #expect(out["notes"] == "moved more")
        #expect(inn["notes"] == "moved more")
        #expect(out["cleared"] == 1)
        #expect(inn["cleared"] == 1)
        // The pair link and transfer payees are untouched.
        #expect(out["transferred_id"] == "leg-in")
        #expect(inn["transferred_id"] == "leg-out")
        #expect(out["description"] == "payee-savings")
        #expect(inn["description"] == "payee-checking")
    }

    @Test func retargetingATransferMovesThePartnerLegAndRemapsPayees() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        let (source, _) = try seedTransfer(into: database)

        try await store.saveTransaction(
            form(transferToAccountId: "acct-brokerage"), editing: source)

        let byId = try rows(path: path)
        let out = try #require(byId["leg-out"])
        let inn = try #require(byId["leg-in"])
        // The receiving leg moved to the new account, and each leg's payee
        // now points at the other side's transfer payee.
        #expect(inn["acct"] == "acct-brokerage")
        #expect(out["acct"] == "acct-checking")
        #expect(out["description"] == "payee-brokerage")
        #expect(inn["description"] == "payee-checking")
    }

    @Test func editingTheDestinationLegUpdatesThePairToo() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        let (_, target) = try seedTransfer(into: database)

        // The user opened the +$25.00 leg in Savings; the form still speaks
        // in From/To (Checking → Savings).
        try await store.saveTransaction(form(amount: "10.00"), editing: target)

        let byId = try rows(path: path)
        #expect(try #require(byId["leg-out"])["amount"] == -1000)
        #expect(try #require(byId["leg-in"])["amount"] == 1000)
    }

    @Test func categoryIsClearedWhenBothAccountsAreOnBudget() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        // A stray category on an on-budget↔on-budget transfer (the bug this
        // fixes let users set one) is stripped on the next save.
        let (source, _) = try seedTransfer(into: database, sourceCategoryId: "cat-food")

        var edit = form()
        edit.categoryId = "cat-food"
        try await store.saveTransaction(edit, editing: source)

        let byId = try rows(path: path)
        #expect(try #require(byId["leg-out"])["category"] == nil)
        #expect(try #require(byId["leg-in"])["category"] == nil)
    }

    @Test func categorySurvivesOnTheOnBudgetLegOfAnOffBudgetTransfer() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        let (source, _) = try seedTransfer(into: database)

        // Re-target to the off-budget Brokerage and categorize the edited
        // (on-budget) leg — money leaving the budget still needs a category.
        var edit = form(transferToAccountId: "acct-brokerage")
        edit.categoryId = "cat-investing"
        try await store.saveTransaction(edit, editing: source)

        let byId = try rows(path: path)
        #expect(try #require(byId["leg-out"])["category"] == "cat-investing")
        #expect(try #require(byId["leg-in"])["category"] == nil)
    }

    @Test func missingPartnerLegIsRefusedAndLeavesTheRowIntact() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        let dangling = Transaction(
            id: "leg-out", accountId: "acct-checking", date: 20260610, amount: -2500,
            payeeId: "payee-savings", payeeName: nil, categoryId: nil,
            categoryName: nil, notes: nil, cleared: false, reconciled: false,
            transferId: "leg-gone", isParent: false, parentId: nil, tombstone: false,
            sortOrder: 1000, importedPayee: nil)
        try database.insertTransaction(dangling)

        await #expect(throws: BudgetStoreError.transferPartnerMissing) {
            try await store.saveTransaction(self.form(amount: "40.00"), editing: dangling)
        }

        let byId = try rows(path: path)
        #expect(try #require(byId["leg-out"])["amount"] == -2500)
    }
}
