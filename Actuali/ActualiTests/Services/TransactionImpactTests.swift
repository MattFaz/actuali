import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct TransactionImpactTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.core + [TestSchema.zeroBudgets, """
        INSERT INTO category_groups (id, name, is_income) VALUES ('grp-1', 'Daily', 0);
        INSERT INTO categories (id, name, cat_group, is_income) VALUES ('cat-food', 'Groceries', 'grp-1', 0);
        INSERT INTO categories (id, name, cat_group, is_income) VALUES ('cat-fun', 'Fun', 'grp-1', 0);
        INSERT INTO category_mapping (id, transferId) VALUES ('cat-food', 'cat-food');
        INSERT INTO category_mapping (id, transferId) VALUES ('cat-fun', 'cat-fun');
        INSERT INTO accounts (id, name, offbudget, tombstone) VALUES ('acct-1', 'Checking', 0, 0);
        INSERT INTO accounts (id, name, offbudget, tombstone) VALUES ('acct-2', 'Savings', 0, 0);
        INSERT INTO zero_budgets (id, month, category, amount) VALUES ('202607-cat-food', 202607, 'cat-food', 10000);
        INSERT INTO zero_budgets (id, month, category, amount) VALUES ('202607-cat-fun', 202607, 'cat-fun', 5000);
        """])
    }

    private func makeStore(_ database: BudgetDatabase) async throws -> BudgetStore {
        let store = try await makeTestStore(database: database)
        store.currentBudgetId = "budget-1"
        store.accounts = [
            Account(id: "acct-1", name: "Checking", type: .checking, offBudget: false, closed: false, sortOrder: 0, balance: 0),
            Account(id: "acct-2", name: "Savings", type: .savings, offBudget: false, closed: false, sortOrder: 1, balance: 0),
        ]
        return store
    }

    private func transaction(_ id: String, amount: Int, categoryId: String? = "cat-food") -> Transaction {
        Transaction(
            id: id, accountId: "acct-1", date: 20_260_710, amount: amount,
            payeeId: nil, payeeName: nil, categoryId: categoryId, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: 100
        )
    }

    private func form(amount: String, categoryId: String?) -> BudgetStore.TransactionForm {
        var form = BudgetStore.TransactionForm(
            accountId: "acct-1", type: .expense, amount: amount, payeeName: "",
            transferToAccountId: nil, categoryId: categoryId, notes: "",
            date: Transaction.date(fromYYYYMMDD: 20_260_710), cleared: false
        )
        form.categoryIsExplicit = true
        return form
    }

    @Test
    func monthComesFromTheDayInteger() {
        #expect(TransactionImpact.month(forDate: 20_260_710) == "2026-07")
        #expect(TransactionImpact.month(forDate: 20_261_231) == "2026-12")
    }

    @Test
    func cuesCoverOnlyBalancesThatMoved() {
        let food = TransactionImpactTarget(month: "2026-07", categoryId: "cat-food")
        let fun = TransactionImpactTarget(month: "2026-07", categoryId: "cat-fun")
        let missing = TransactionImpactTarget(month: "2026-07", categoryId: "cat-gone")
        let cues = TransactionImpact.cues(
            before: [food: ("Groceries", 10000), fun: ("Fun", 5000), missing: ("Gone", 1)],
            after: [food: ("Groceries", 9000), fun: ("Fun", 5000)]
        )
        #expect(cues.count == 1)
        #expect(cues[0].categoryName == "Groceries")
        #expect(cues[0].deltaCents == -1000)
        #expect(cues[0].isExpense)
    }

    @Test
    func cuesAreOrderedByMonthThenName() {
        let a = TransactionImpactTarget(month: "2026-08", categoryId: "a")
        let b = TransactionImpactTarget(month: "2026-07", categoryId: "b")
        let c = TransactionImpactTarget(month: "2026-07", categoryId: "c")
        let cues = TransactionImpact.cues(
            before: [a: ("Alpha", 0), b: ("Zulu", 0), c: ("Bravo", 0)],
            after: [a: ("Alpha", 1), b: ("Zulu", 1), c: ("Bravo", 1)]
        )
        #expect(cues.map(\.categoryName) == ["Bravo", "Zulu", "Alpha"])
    }

    @Test
    func savingAnExpenseShowsTheCategoryBalanceBeforeAndAfter() async throws {
        let (database, url) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try await makeStore(database)

        _ = try await store.saveTransaction(form(amount: "25.00", categoryId: "cat-food"))

        let cue = try #require(store.transactionImpactCues.first)
        #expect(store.transactionImpactCues.count == 1)
        #expect(cue.categoryName == "Groceries")
        #expect(cue.balanceBeforeCents == 10000)
        #expect(cue.balanceAfterCents == 7500)
        #expect(cue.deltaCents == -2500)
    }

    @Test
    func deletingATransactionShowsTheBalanceComingBack() async throws {
        let (database, url) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try await makeStore(database)
        let tx = transaction("tx-1", amount: -3000)
        try database.insertTransaction(tx)

        await store.deleteTransactions([tx])

        let cue = try #require(store.transactionImpactCues.first)
        #expect(cue.balanceBeforeCents == 7000)
        #expect(cue.balanceAfterCents == 10000)
        #expect(!cue.isExpense)
    }

    @Test
    func uncategorizedAndOffBudgetChangesShowNothing() async throws {
        let (database, url) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try await makeStore(database)

        _ = try await store.saveTransaction(form(amount: "10.00", categoryId: nil))
        #expect(store.transactionImpactCues.isEmpty)

        let uncategorized = transaction("tx-2", amount: -500, categoryId: nil)
        try database.insertTransaction(uncategorized)
        await store.deleteTransactions([uncategorized])
        #expect(store.transactionImpactCues.isEmpty)
    }

    @Test
    func theSettingAndHiddenBalancesTurnThePopupOff() async throws {
        let (database, url) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try await makeStore(database)

        store.showTransactionImpactCue = false
        _ = try await store.saveTransaction(form(amount: "5.00", categoryId: "cat-food"))
        #expect(store.transactionImpactCues.isEmpty)

        store.showTransactionImpactCue = true
        store.hideBalances = true
        _ = try await store.saveTransaction(form(amount: "5.00", categoryId: "cat-food"))
        #expect(store.transactionImpactCues.isEmpty)
        store.hideBalances = false
        store.showTransactionImpactCue = true
    }

    @Test
    func tappingDismissesThePopup() async throws {
        let (database, url) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try await makeStore(database)
        _ = try await store.saveTransaction(form(amount: "25.00", categoryId: "cat-food"))
        #expect(!store.transactionImpactCues.isEmpty)

        store.dismissTransactionImpactCues()
        #expect(store.transactionImpactCues.isEmpty)
    }
}
