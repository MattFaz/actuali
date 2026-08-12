import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreSaveTransactionTests {

    /// transactions, payees and messages_crdt normally come from the
    /// downloaded budget file, so create them with the upstream schema
    /// (matches BudgetDatabaseTransferAtomicityTests).
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
                )
                """)
            try db.execute(sql: """
                CREATE TABLE payees (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    transfer_acct TEXT,
                    tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE payee_mapping (
                    id TEXT PRIMARY KEY,
                    targetId TEXT
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
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    /// Store wired to a real database and sync client so saveTransaction can
    /// run end-to-end. The server client is unconfigured, so the post-write
    /// automatic sync fails fast and locally without touching the network.
    private func makeStore(database: BudgetDatabase) async throws -> BudgetStore {
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)
        return store
    }

    private func transactionRows(path: URL) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM transactions ORDER BY id")
        }
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func form(
        type: TransactionType = .expense,
        amount: String = "10.50",
        payeeName: String = "",
        transferToAccountId: String? = nil
    ) -> BudgetStore.TransactionForm {
        BudgetStore.TransactionForm(
            accountId: "acct-1",
            type: type,
            amount: amount,
            payeeName: payeeName,
            transferToAccountId: transferToAccountId,
            categoryId: nil,
            notes: "",
            date: Date(),
            cleared: false
        )
    }

    private func payee(id: String, name: String) -> Payee {
        Payee(id: id, name: name, transferAccountId: nil, tombstone: false)
    }

    private func transaction(payeeId: String?, payeeName: String?) -> Transaction {
        Transaction(
            id: "tx-1",
            accountId: "acct-1",
            date: 20260610,
            amount: -500,
            payeeId: payeeId,
            payeeName: payeeName,
            categoryId: nil,
            categoryName: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )
    }

    // MARK: - Routing (transfer vs regular) and amount signing

    @Test func expenseAmountsBecomeNegativeCents() throws {
        let plan = try BudgetStore.plan(for: form(type: .expense, amount: "10.50"))
        #expect(plan == .standard(amountCents: -1050))
    }

    @Test func incomeAmountsStayPositive() throws {
        let plan = try BudgetStore.plan(for: form(type: .income, amount: "10.50"))
        #expect(plan == .standard(amountCents: 1050))
    }

    @Test func transferRoutesToDestinationWithUnsignedAmount() throws {
        let plan = try BudgetStore.plan(
            for: form(type: .transfer, amount: "25.00", transferToAccountId: "acct-2")
        )
        #expect(plan == .transfer(toAccountId: "acct-2", amountCents: 2500))
    }

    @Test func transferWithoutDestinationIsRejected() {
        #expect(throws: BudgetStoreError.missingTransferDestination) {
            try BudgetStore.plan(for: form(type: .transfer, transferToAccountId: nil))
        }
    }

    @Test func unparseableAmountIsRejected() {
        #expect(throws: BudgetStoreError.invalidAmount) {
            try BudgetStore.plan(for: form(amount: "not a number"))
        }
    }

    // MARK: - Payee resolution (find-or-create)

    @Test func emptyPayeeNameClearsThePayee() async throws {
        let store = BudgetStore.previewInstance()
        let original = transaction(payeeId: "p-1", payeeName: "Grocer")
        let resolved = try await store.resolvePayeeId(name: "", editing: original)
        #expect(resolved == nil)
    }

    @Test func unchangedPayeeNameKeepsTheOriginalPayee() async throws {
        // No payees seeded and no sync client: any find-or-create attempt
        // would throw, so success proves the original id is reused directly.
        let store = BudgetStore.previewInstance()
        let original = transaction(payeeId: "p-1", payeeName: "Grocer")
        let resolved = try await store.resolvePayeeId(name: "Grocer", editing: original)
        #expect(resolved == "p-1")
    }

    @Test func existingPayeeIsFoundCaseInsensitively() async throws {
        let store = BudgetStore.previewInstance()
        store.payees = [payee(id: "p-joe", name: "Trader Joe's")]
        let resolved = try await store.resolvePayeeId(name: "TRADER JOE'S", editing: nil)
        #expect(resolved == "p-joe")
        #expect(store.payees.count == 1)  // matched, not created
    }

    @Test func newPayeeNameTriggersCreation() async {
        // The preview store has no sync client, so the create path surfaces
        // as payeeCreationFailed — proving the name missed the find path.
        let store = BudgetStore.previewInstance()
        store.payees = [payee(id: "p-joe", name: "Trader Joe's")]
        await #expect(throws: BudgetStoreError.payeeCreationFailed("Sync not configured")) {
            _ = try await store.resolvePayeeId(name: "Whole Foods", editing: nil)
        }
    }

    @Test func findOrCreatePayeeReturnsExistingMatch() async throws {
        let store = BudgetStore.previewInstance()
        store.payees = [payee(id: "p-1", name: "Bakery"), payee(id: "p-2", name: "Butcher")]
        let found = try await store.findOrCreatePayee(name: "bakery")
        #expect(found.id == "p-1")
        #expect(store.payees.count == 2)
    }

    // MARK: - End-to-end save (create and edit)

    @Test func savingANewTransactionPersistsRowWithImportedPayee() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await store.saveTransaction(
            form(type: .expense, amount: "10.50", payeeName: "Trader Joe's")
        )

        let rows = try transactionRows(path: path)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["acct"] == "acct-1")
        #expect(row["amount"] == -1050)
        // New transactions record the typed payee name as imported_description
        #expect(row["imported_description"] == "Trader Joe's")
        // The payee was created and linked
        let createdPayee = try #require(store.payees.first { $0.name == "Trader Joe's" })
        #expect(row["description"] == createdPayee.id)
        #expect(row["tombstone"] == 0)
    }

    @Test func editingATransactionPreservesImportedPayeeAndCarriedFields() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        // Seed an existing transaction the way a bank import would leave it:
        // reconciled, linked to a transfer leg, with an imported payee memo.
        var original = transaction(payeeId: "p-1", payeeName: "Grocer")
        original.reconciled = true
        original.transferId = "leg-2"
        original.importedPayee = "RAW BANK MEMO"
        try database.insertTransaction(original)
        let seeded = try #require(try transactionRows(path: path).first)
        let seededSortOrder: Double = try #require(seeded["sort_order"])
        original.sortOrder = seededSortOrder

        // Edit: change the amount, keep the payee name unchanged.
        var edit = form(type: .expense, amount: "7.25", payeeName: "Grocer")
        edit.notes = "edited"
        try await store.saveTransaction(edit, editing: original)

        let rows = try transactionRows(path: path)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["amount"] == -725)
        #expect(row["notes"] == "edited")
        // Edits must not rewrite the imported payee memo
        #expect(row["imported_description"] == "RAW BANK MEMO")
        // Carried-over fields survive the edit
        #expect(row["reconciled"] == 1)
        #expect(row["transferred_id"] == "leg-2")
        #expect(row["sort_order"] == seededSortOrder)
        #expect(row["description"] == "p-1")
    }

    @Test func editingIntoATransferIsRejectedAndLeavesOriginalIntact() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        let original = transaction(payeeId: "p-1", payeeName: "Grocer")
        try database.insertTransaction(original)

        // Converting an existing transaction into a transfer would create a new
        // transfer pair and orphan the original (actios-7u6). It must be refused.
        var edit = form(type: .transfer, amount: "25.00", transferToAccountId: "acct-2")
        edit.payeeName = "Grocer"
        await #expect(throws: BudgetStoreError.cannotConvertToTransfer) {
            try await store.saveTransaction(edit, editing: original)
        }

        // No new transfer legs created; the original row is untouched.
        let rows = try transactionRows(path: path)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["id"] == "tx-1")
        #expect(row["amount"] == -500)
        #expect(row["tombstone"] == 0)
    }

    // MARK: - YYYYMMDD encoding

    @Test func yyyymmddRoundTripsThroughDate() {
        let encoded = 20251209
        let decoded = Transaction.date(fromYYYYMMDD: encoded)
        #expect(Transaction.yyyymmdd(from: decoded) == encoded)
    }
}
