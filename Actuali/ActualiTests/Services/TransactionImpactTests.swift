import Foundation
import GRDB
import class SwiftUI.UIHostingController
import Testing
@testable import Actuali

@MainActor
struct TransactionImpactTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.core + [TestSchema.zeroBudgets, TestSchema.rules, """
        INSERT INTO category_groups (id, name, is_income) VALUES ('grp-1', 'Daily', 0);
        INSERT INTO categories (id, name, cat_group, is_income) VALUES ('cat-food', 'Groceries', 'grp-1', 0);
        INSERT INTO categories (id, name, cat_group, is_income) VALUES ('cat-fun', 'Fun', 'grp-1', 0);
        INSERT INTO category_mapping (id, transferId) VALUES ('cat-food', 'cat-food');
        INSERT INTO category_mapping (id, transferId) VALUES ('cat-fun', 'cat-fun');
        INSERT INTO accounts (id, name, offbudget, tombstone) VALUES ('acct-1', 'Checking', 0, 0);
        INSERT INTO accounts (id, name, offbudget, tombstone) VALUES ('acct-2', 'Savings', 1, 0);
        INSERT INTO zero_budgets (id, month, category, amount) VALUES ('202607-cat-food', 202607, 'cat-food', 10000);
        INSERT INTO zero_budgets (id, month, category, amount) VALUES ('202607-cat-fun', 202607, 'cat-fun', 5000);
        """])
    }

    private func makeStore(_ database: BudgetDatabase) async throws -> BudgetStore {
        let store = try await makeTestStore(database: database)
        store.currentBudgetId = "budget-1"
        store.accounts = [
            Account(id: "acct-1", name: "Checking", type: .checking, offBudget: false, closed: false, sortOrder: 0, balance: 0),
            Account(id: "acct-2", name: "Savings", type: .savings, offBudget: true, closed: false, sortOrder: 1, balance: 0),
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
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }

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
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        let tx = transaction("tx-1", amount: -3000)
        try database.insertTransaction(tx)

        await store.deleteTransactions([tx])

        let cue = try #require(store.transactionImpactCues.first)
        #expect(cue.balanceBeforeCents == 7000)
        #expect(cue.balanceAfterCents == 10000)
        #expect(!cue.isExpense)
    }

    @Test
    func uncategorizedChangesShowNothing() async throws {
        let (database, url) = try await makeDatabase()
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }

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
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }

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
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        _ = try await store.saveTransaction(form(amount: "25.00", categoryId: "cat-food"))
        #expect(!store.transactionImpactCues.isEmpty)

        store.dismissTransactionImpactCues()
        #expect(store.transactionImpactCues.isEmpty)
    }

    @Test
    func offBudgetAndTransfersShowNothing() async throws {
        let (database, url) = try await makeDatabase()
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        var offBudget = form(amount: "10.00", categoryId: "cat-food")
        offBudget.accountId = "acct-2"
        _ = try await store.saveTransaction(offBudget)
        #expect(store.transactionImpactCues.isEmpty)
        var transfer = transaction("transfer", amount: -1000)
        transfer.transferId = "partner"
        #expect(await store.impactTargets(for: [transfer]).isEmpty)
        var transferForm = form(amount: "10.00", categoryId: "cat-food")
        transferForm.type = .transfer
        #expect(store.impactTargets(for: transferForm).isEmpty)
    }

    @Test
    func splitAndCategoryEditsShowEveryChangedCategory() async throws {
        let (database, url) = try await makeDatabase()
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        var split = form(amount: "30.00", categoryId: nil)
        split.splits = [
            .init(categoryId: "cat-food", amount: "10.00"),
            .init(categoryId: "cat-fun", amount: "20.00"),
        ]
        _ = try await store.saveTransaction(split)
        #expect(Set(store.transactionImpactCues.map(\.deltaCents)) == [-1000, -2000])
        let parent = try #require(store.transactions.first { $0.isParent })
        await store.deleteTransactions([parent])
        #expect(Set(store.transactionImpactCues.map(\.deltaCents)) == [1000, 2000])

        let original = transaction("edit", amount: -1000)
        try database.insertTransaction(original)
        _ = try await store.saveTransaction(form(amount: "10.00", categoryId: "cat-fun"), editing: original)
        #expect(store.transactionImpactCues.count == 2)
        #expect(store.transactionImpactCues.first { $0.categoryId == "cat-food" }?.deltaCents == 1000)
        #expect(store.transactionImpactCues.first { $0.categoryId == "cat-fun" }?.deltaCents == -1000)
    }

    @Test
    func movingAnExpenseToAnotherMonthShowsBothMonths() async throws {
        let (database, url) = try await makeDatabase()
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        let original = transaction("move", amount: -1000)
        try database.insertTransaction(original)
        var edited = form(amount: "10.00", categoryId: "cat-fun")
        edited.date = Transaction.date(fromYYYYMMDD: 20_260_810)
        _ = try await store.saveTransaction(edited, editing: original)
        #expect(store.transactionImpactCues.map(\.month) == ["2026-07", "2026-08"])
        #expect(store.transactionImpactCues.map(\.deltaCents) == [1000, -1000])
    }

    @Test
    func rulesChooseTheActualCategoryAndMonthForTheCue() async throws {
        let (database, url) = try await makeDatabase()
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
            INSERT INTO rules (id, conditions_op, conditions, actions)
            VALUES ('categorize', 'and', '[{"op":"is","field":"amount","value":-1000}]',
                '[{"op":"set","field":"category","value":"cat-fun"},
                  {"op":"set","field":"date","value":"2026-08-10"}]');
            """)
        }
        var input = form(amount: "10.00", categoryId: nil)
        input.categoryIsExplicit = false
        let id = try #require(try await store.saveTransaction(input))
        let saved = try #require(try await database.fetchTransaction(id: id))
        #expect(saved.categoryId == "cat-fun")
        #expect(saved.date == 20_260_810)
        let cue = try #require(store.transactionImpactCues.first)
        #expect(cue.categoryId == "cat-fun")
        #expect(cue.month == "2026-08")
        #expect(cue.deltaCents == -1000)
    }

    @Test
    func disablingDuringAWriteSuppressesThePopup() async throws {
        let (database, url) = try await makeDatabase()
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        await store.withImpactCue(touching: [TransactionImpactTarget(month: "2026-07", categoryId: "cat-food")]) {
            try? database.insertTransaction(transaction("tx", amount: -1000))
            store.showTransactionImpactCue = false
        }
        #expect(store.transactionImpactCues.isEmpty)
        store.showTransactionImpactCue = true
    }

    @Test
    func changingPrivacySettingsOrBudgetDismissesAnExistingCue() async throws {
        let (database, url) = try await makeDatabase()
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        _ = try await store.saveTransaction(form(amount: "1.00", categoryId: "cat-food"))
        store.hideBalances = true
        #expect(store.transactionImpactCues.isEmpty)
        store.hideBalances = false
        _ = try await store.saveTransaction(form(amount: "1.00", categoryId: "cat-food"))
        store.showTransactionImpactCue = false
        #expect(store.transactionImpactCues.isEmpty)
        store.showTransactionImpactCue = true
        _ = try await store.saveTransaction(form(amount: "1.00", categoryId: "cat-food"))
        store.currentBudgetId = "another-budget"
        #expect(store.transactionImpactCues.isEmpty)
    }

    @Test
    func aBudgetSwitchDuringTheWriteSuppressesTheOldBudgetCue() async throws {
        let (database, url) = try await makeDatabase()
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        await store.withImpactCue(touching: [TransactionImpactTarget(month: "2026-07", categoryId: "cat-food")]) {
            try? database.insertTransaction(transaction("switch", amount: -1000))
            store.currentBudgetId = "other"
        }
        #expect(store.transactionImpactCues.isEmpty)
    }

    @Test
    func duplicatingAndCategorizingShowTheActualBalanceChange() async throws {
        let (database, url) = try await makeDatabase()
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        let original = transaction("duplicate", amount: -1000)
        try database.insertTransaction(original)
        await store.duplicateTransactions([original])
        #expect(store.transactionImpactCues.first?.deltaCents == -1000)
        let uncategorized = transaction("uncategorized", amount: -500, categoryId: nil)
        try database.insertTransaction(uncategorized)
        var categorized = uncategorized
        categorized.categoryId = "cat-food"
        try await store.withImpactCue(for: [uncategorized, categorized]) {
            try await store.updateTransaction(categorized, original: uncategorized)
        }
        #expect(store.transactionImpactCues.first?.deltaCents == -500)
    }

    @Test
    func failedWritesAndUnchangedBalancesShowNothing() async throws {
        let (database, url) = try await makeDatabase()
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        let original = transaction("same", amount: -1000)
        try database.insertTransaction(original)
        _ = try await store.saveTransaction(form(amount: "10.00", categoryId: "cat-food"), editing: original)
        #expect(store.transactionImpactCues.isEmpty)
        await #expect(throws: BudgetStoreError.self) {
            try await store.saveTransaction(form(amount: "invalid", categoryId: "cat-food"))
        }
        #expect(store.transactionImpactCues.isEmpty)
    }

    @Test
    func historicalMonthIsPartOfTheSpokenBalance() async throws {
        let (database, url) = try await makeDatabase()
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        let cue = TransactionImpactCue(categoryId: "cat-food", categoryName: "Groceries", month: "2020-01", balanceBeforeCents: 1000, balanceAfterCents: 500)
        #expect(store.spokenImpactText(cue).contains(MonthPicker.title(for: "2020-01")))
    }

    @Test
    func theCueDismissesAutomatically() async throws {
        let (database, url) = try await makeDatabase()
        let store = try await makeStore(database)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        _ = try await store.saveTransaction(form(amount: "1.00", categoryId: "cat-food"))
        #expect(!store.transactionImpactCues.isEmpty)
        try await Task.sleep(for: .seconds(TransactionImpact.autoDismissSeconds + 0.2))
        #expect(store.transactionImpactCues.isEmpty)
    }

    @Test
    func bulkCardsStayBoundedAndASingleCardFitsItsContent() {
        let store = BudgetStore.previewInstance()
        func height(for count: Int) -> CGFloat {
            store.transactionImpactCues = (0..<count).map { index in
                TransactionImpactCue(categoryId: "cat-\(index)", categoryName: "Groceries", month: "2020-01", balanceBeforeCents: 1000, balanceAfterCents: 500)
            }
            let host = UIHostingController(rootView: TransactionImpactPopup().environmentObject(store))
            return host.sizeThatFits(in: CGSize(width: 390, height: 844)).height
        }
        let singleHeight = height(for: 1)
        #expect(singleHeight > 0)
        #expect(singleHeight < 150)
        let bulkHeight = height(for: 20)
        #expect(bulkHeight > singleHeight)
        #expect(bulkHeight <= 300)
    }
}
