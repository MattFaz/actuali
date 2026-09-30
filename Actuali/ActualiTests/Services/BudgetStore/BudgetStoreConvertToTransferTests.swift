import Foundation
import GRDB
import Testing
@testable import Actuali

/// End-to-end coverage for turning an ordinary (often bank-imported)
/// transaction into a transfer through `saveTransaction` → `convertToTransfer`
/// (GH #259): the row keeps its id, account, direction and history, its payee
/// becomes the other account's transfer payee, and a partner leg is created
/// for the opposite amount.
@MainActor
struct BudgetStoreConvertToTransferTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.core + ["""
        INSERT INTO accounts (id, name, offbudget) VALUES
            ('acct-checking',  'Checking',  0),
            ('acct-card',      'Card',      0),
            ('acct-brokerage', 'Brokerage', 1);

        -- One transfer payee per account, like Actual maintains.
        INSERT INTO payees (id, name, transfer_acct) VALUES
            ('payee-checking',  NULL, 'acct-checking'),
            ('payee-card',      NULL, 'acct-card'),
            ('payee-brokerage', NULL, 'acct-brokerage');

        INSERT INTO payee_mapping (id, targetId) VALUES
            ('payee-checking',  'payee-checking'),
            ('payee-card',      'payee-card'),
            ('payee-brokerage', 'payee-brokerage');
        """])
    }

    /// Store wired to a real database and sync client, with the accounts and
    /// transfer payees mirrored into the in-memory caches the conversion
    /// reads (`accounts` for the off-budget rule, `payees` for payee lookup).
    private func makeStore(database: BudgetDatabase) async throws -> BudgetStore {
        let store = try await makeTestStore(database: database)
        store.accounts = [
            Account(id: "acct-checking", name: "Checking", type: .checking,
                    offBudget: false, closed: false, sortOrder: 0, balance: 0),
            Account(id: "acct-card", name: "Card", type: .credit,
                    offBudget: false, closed: false, sortOrder: 1, balance: 0),
            Account(id: "acct-brokerage", name: "Brokerage", type: .investment,
                    offBudget: true, closed: false, sortOrder: 2, balance: 0),
        ]
        store.payees = [
            Payee(id: "payee-checking", name: "", transferAccountId: "acct-checking", tombstone: false),
            Payee(id: "payee-card", name: "", transferAccountId: "acct-card", tombstone: false),
            Payee(id: "payee-brokerage", name: "", transferAccountId: "acct-brokerage", tombstone: false),
            Payee(id: "payee-bank", name: "BANK", transferAccountId: nil, tombstone: false),
        ]
        return store
    }

    /// An imported transaction as a bank feed leaves it: cleared, reconciled,
    /// with the raw memo in `imported_description` and a plain payee.
    private func seedImported(
        into database: BudgetDatabase,
        accountId: String = "acct-checking",
        amount: Int = -25000,
        categoryId: String? = nil,
        isParent: Bool = false,
        parentId: String? = nil
    ) throws -> Transaction {
        let imported = Transaction(
            id: "tx-imported", accountId: accountId, date: 20_260_610, amount: amount,
            payeeId: "payee-bank", payeeName: "BANK", categoryId: categoryId,
            categoryName: nil, notes: "card payment", cleared: true, reconciled: true,
            transferId: nil, isParent: isParent, parentId: parentId, tombstone: false,
            sortOrder: 1000, importedPayee: "RAW BANK MEMO"
        )
        try database.insertTransaction(imported)
        return imported
    }

    private func form(
        accountId: String = "acct-checking",
        amount: String = "250.00",
        transferToAccountId: String? = "acct-card",
        categoryId: String? = nil,
        notes: String = "card payment",
        cleared: Bool = true
    ) -> BudgetStore.TransactionForm {
        BudgetStore.TransactionForm(
            accountId: accountId,
            type: .transfer,
            amount: amount,
            payeeName: "",
            transferToAccountId: transferToAccountId,
            categoryId: categoryId,
            notes: notes,
            date: Transaction.date(fromYYYYMMDD: 20_260_610),
            cleared: cleared
        )
    }

    private func rows(path: URL) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM transactions")
        }
    }

    @Test func convertingAnImportedOutflowPairsItWithANewLeg() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        let imported = try seedImported(into: database)

        try await store.saveTransaction(form(), editing: imported)

        let all = try rows(path: path)
        #expect(all.count == 2)
        let leg = try #require(all.first { $0["id"] as String == "tx-imported" })
        let partner = try #require(all.first { $0["id"] as String != "tx-imported" })

        // The imported row keeps its id, account, direction and history.
        #expect(leg["acct"] == "acct-checking")
        #expect(leg["amount"] == -25000)
        #expect(leg["reconciled"] == 1)
        #expect(leg["cleared"] == 1)
        #expect(leg["imported_description"] == "RAW BANK MEMO")
        #expect(leg["sort_order"] == 1000.0)
        // Its payee is now the other account's transfer payee, and the pair
        // links both ways.
        #expect(leg["description"] == "payee-card")
        #expect(leg["transferred_id"] == (partner["id"] as String))
        #expect(partner["transferred_id"] == "tx-imported")

        // The new leg mirrors the amount in the other account, carries the
        // notes, and starts uncleared (upstream addTransfer).
        #expect(partner["acct"] == "acct-card")
        #expect(partner["amount"] == 25000)
        #expect(partner["description"] == "payee-checking")
        #expect(partner["notes"] == "card payment")
        #expect(partner["cleared"] == 0)
        #expect(partner["reconciled"] == 0)
        #expect(partner["tombstone"] == 0)
    }

    @Test func convertingAnImportedInflowKeepsItsDirection() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        // The same card payment, imported on the card side as an inflow.
        let imported = try seedImported(into: database, accountId: "acct-card", amount: 25000)

        try await store.saveTransaction(
            form(accountId: "acct-card", transferToAccountId: "acct-checking"),
            editing: imported
        )

        let all = try rows(path: path)
        let leg = try #require(all.first { $0["id"] as String == "tx-imported" })
        let partner = try #require(all.first { $0["id"] as String != "tx-imported" })
        // The bank's own sign survives the conversion; the new leg takes the
        // outflow side.
        #expect(leg["acct"] == "acct-card")
        #expect(leg["amount"] == 25000)
        #expect(partner["acct"] == "acct-checking")
        #expect(partner["amount"] == -25000)
        #expect(leg["description"] == "payee-checking")
        #expect(partner["description"] == "payee-card")
    }

    @Test func convertingAppliesTheFormsAmountDateAndNotes() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        let imported = try seedImported(into: database)

        var edit = form(amount: "300.00", notes: "fixed up")
        edit.date = Transaction.date(fromYYYYMMDD: 20_260_715)
        try await store.saveTransaction(edit, editing: imported)

        let all = try rows(path: path)
        let leg = try #require(all.first { $0["id"] as String == "tx-imported" })
        let partner = try #require(all.first { $0["id"] as String != "tx-imported" })
        #expect(leg["amount"] == -30000)
        #expect(partner["amount"] == 30000)
        #expect(leg["date"] == 20_260_715)
        #expect(partner["date"] == 20_260_715)
        #expect(leg["notes"] == "fixed up")
        #expect(partner["notes"] == "fixed up")
    }

    @Test func convertingHonoursAnAccountChangeMadeInTheSameEdit() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        let imported = try seedImported(into: database)

        // Moving a transaction between accounts is an ordinary edit, and the
        // account picker stays live while Transfer is selected — a save that
        // does both lands the leg in the account the form names.
        try await store.saveTransaction(
            form(accountId: "acct-brokerage", transferToAccountId: "acct-card"),
            editing: imported
        )

        let all = try rows(path: path)
        let leg = try #require(all.first { $0["id"] as String == "tx-imported" })
        let partner = try #require(all.first { $0["id"] as String != "tx-imported" })
        #expect(leg["acct"] == "acct-brokerage")
        #expect(leg["amount"] == -25000)
        #expect(partner["acct"] == "acct-card")
        #expect(leg["description"] == "payee-card")
        #expect(partner["description"] == "payee-brokerage")
    }

    @Test func convertingClearsTheCategoryBetweenTwoOnBudgetAccounts() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        // Imported and auto-categorized before the user reclassified it.
        let imported = try seedImported(into: database, categoryId: "cat-bills")

        var edit = form()
        edit.categoryId = "cat-bills"
        try await store.saveTransaction(edit, editing: imported)

        let all = try rows(path: path)
        #expect(all.allSatisfy { $0["category"] == nil })
    }

    @Test func convertingKeepsTheCategoryWhenTheOtherAccountIsOffBudget() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        let imported = try seedImported(into: database)

        // Money leaving the budget still needs a category on the on-budget leg.
        var edit = form(transferToAccountId: "acct-brokerage")
        edit.categoryId = "cat-investing"
        try await store.saveTransaction(edit, editing: imported)

        let all = try rows(path: path)
        let leg = try #require(all.first { $0["id"] as String == "tx-imported" })
        let partner = try #require(all.first { $0["id"] as String != "tx-imported" })
        #expect(leg["category"] == "cat-investing")
        #expect(partner["category"] == nil)
    }

    @Test func convertingASplitParentIsRefused() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        let parent = try seedImported(into: database, isParent: true)

        await #expect(throws: BudgetStoreError.cannotConvertToTransfer) {
            try await store.saveTransaction(self.form(), editing: parent)
        }
        #expect(try rows(path: path).count == 1)
    }

    @Test func convertingASplitChildIsRefused() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        let child = try seedImported(into: database, parentId: "tx-parent")

        await #expect(throws: BudgetStoreError.cannotConvertToTransfer) {
            try await store.saveTransaction(self.form(), editing: child)
        }
        #expect(try rows(path: path).count == 1)
    }

    @Test func convertingIntoTheSameAccountIsRefused() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        let imported = try seedImported(into: database)

        await #expect(throws: BudgetStoreError.transferAccountsMatch) {
            try await store.saveTransaction(
                self.form(transferToAccountId: "acct-checking"), editing: imported
            )
        }
        #expect(try rows(path: path).count == 1)
    }
}
