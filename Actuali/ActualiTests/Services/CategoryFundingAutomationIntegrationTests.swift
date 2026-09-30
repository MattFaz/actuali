import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct CategoryFundingAutomationIntegrationTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.core + [TestSchema.zeroBudgets, """
        INSERT INTO category_groups (id, name, is_income) VALUES ('grp-1', 'Daily', 0);
        INSERT INTO categories (id, name, cat_group, is_income) VALUES ('cat-dining', 'Dining Out', 'grp-1', 0);
        INSERT INTO categories (id, name, cat_group, is_income) VALUES ('cat-emergency', 'Emergency Fund', 'grp-1', 0);
        INSERT INTO categories (id, name, cat_group, is_income) VALUES ('cat-income', 'Salary', 'grp-1', 1);
        INSERT INTO category_mapping (id, transferId) VALUES ('cat-dining', 'cat-dining');
        INSERT INTO category_mapping (id, transferId) VALUES ('cat-emergency', 'cat-emergency');
        INSERT INTO category_mapping (id, transferId) VALUES ('cat-income', 'cat-income');
        INSERT INTO accounts (id, name, offbudget, tombstone) VALUES ('acct-1', 'Checking', 0, 0);
        INSERT INTO zero_budgets (id, month, category, amount) VALUES ('202607-cat-dining', 202607, 'cat-dining', 1000);
        INSERT INTO zero_budgets (id, month, category, amount) VALUES ('202607-cat-emergency', 202607, 'cat-emergency', 2000);
        INSERT INTO zero_budgets (id, month, category, amount) VALUES ('202607-cat-income', 202607, 'cat-income', 2000);
        """])
    }

    private func makeStore(database: BudgetDatabase) async throws -> BudgetStore {
        let store = try await makeTestStore(database: database)
        store.currentBudgetId = "budget-1"
        store.accounts = [
            Account(
                id: "acct-1",
                name: "Checking",
                type: .checking,
                offBudget: false,
                closed: false,
                sortOrder: 0,
                balance: -1500
            ),
        ]
        store.categoryGroups = [
            CategoryGroup(
                id: "grp-1",
                name: "Daily",
                isIncome: false,
                hidden: false,
                sortOrder: 0,
                categories: [
                    Category(
                        id: "cat-dining",
                        name: "Dining Out",
                        groupId: "grp-1",
                        isIncome: false,
                        hidden: false,
                        sortOrder: 0
                    ),
                    Category(
                        id: "cat-emergency",
                        name: "Emergency Fund",
                        groupId: "grp-1",
                        isIncome: false,
                        hidden: false,
                        sortOrder: 1
                    ),
                    Category(
                        id: "cat-income",
                        name: "Salary",
                        groupId: "grp-1",
                        isIncome: true,
                        hidden: false,
                        sortOrder: 2
                    ),
                ]
            ),
        ]
        return store
    }

    private func saveConfiguration(
        _ source: CategoryFundingSource,
        defaults: UserDefaults
    ) {
        CategoryFundingAutomation.saveConfiguration(
            CategoryFundingAutomationConfiguration(
                isEnabled: true,
                accountId: "acct-1",
                fundingSource: source
            ),
            for: "budget-1",
            defaults: defaults
        )
    }

    private func insertTransaction(
        in database: BudgetDatabase,
        id: String = "tx-1",
        amount: Int = -1500,
        categoryId: String = "cat-dining",
        accountId: String = "acct-1"
    ) throws -> Transaction {
        let transaction = Transaction(
            id: id,
            accountId: accountId,
            date: 20_260_725,
            amount: amount,
            payeeId: nil,
            payeeName: "Restaurant",
            categoryId: categoryId,
            categoryName: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: "Restaurant"
        )
        try database.insertTransaction(transaction)
        return transaction
    }

    @Test("Automatic funding covers only the new expense shortfall")
    func automaticFundingCoversOnlyNewShortfall() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        let transaction = try insertTransaction(in: database)

        let suiteName = "CategoryFundingAutomationIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        saveConfiguration(.toBudget, defaults: defaults)

        let before = try await database.fetchBudgetMonth(month: "2026-07")
        let beforeDining = try #require(before.categoryBudgets.first { $0.categoryId == "cat-dining" })
        #expect(!before.isTrackingBudget)
        #expect(beforeDining.budgeted == 1000)
        #expect(beforeDining.spent == -1500)
        #expect(beforeDining.available == -500)
        #expect(CategoryFundingAutomation.fundingDecision(
            transactionAmount: transaction.amount,
            availableAfterTransaction: beforeDining.available,
            targetCategoryId: beforeDining.categoryId,
            fundingSource: .toBudget,
            isTrackingBudget: before.isTrackingBudget
        ) == .fund(500))

        await store.fetchBudgetMonth("2026-07")
        await CategoryFundingAutomation.process(
            savedTransactionId: transaction.id,
            using: store,
            defaults: defaults
        )

        #expect(store.error == nil)
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        let dining = try #require(month.categoryBudgets.first { $0.categoryId == "cat-dining" })
        #expect(dining.budgeted == 1500)
        #expect(dining.spent == -1500)
        #expect(dining.available == 0)
    }

    @Test("Funding from another category moves exactly the shortfall")
    func fundsFromSourceCategory() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        let transaction = try insertTransaction(in: database)

        let suiteName = "CategoryFundingAutomationIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        saveConfiguration(.category("cat-emergency"), defaults: defaults)

        await store.fetchBudgetMonth("2026-07")
        await CategoryFundingAutomation.process(
            savedTransactionId: transaction.id,
            using: store,
            defaults: defaults
        )

        #expect(store.error == nil)
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        let dining = try #require(month.categoryBudgets.first { $0.categoryId == "cat-dining" })
        let emergency = try #require(month.categoryBudgets.first { $0.categoryId == "cat-emergency" })
        #expect(dining.budgeted == 1500)
        #expect(dining.available == 0)
        #expect(emergency.budgeted == 1500)
        #expect(emergency.available == 1500)
    }

    @Test("Closed account is not eligible for category funding")
    func closedAccountDoesNotFund() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        _ = try insertTransaction(in: database)
        store.accounts[0].closed = true

        let suiteName = "CategoryFundingAutomationIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        saveConfiguration(.toBudget, defaults: defaults)

        await CategoryFundingAutomation.process(
            savedTransactionId: "tx-1",
            using: store,
            defaults: defaults
        )

        #expect(store.error == nil)
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        let dining = try #require(month.categoryBudgets.first { $0.categoryId == "cat-dining" })
        #expect(dining.budgeted == 1000)
    }

    @Test("Off-budget account is not eligible for category funding")
    func offBudgetAccountDoesNotFund() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        _ = try insertTransaction(in: database)
        store.accounts[0].offBudget = true

        let suiteName = "CategoryFundingAutomationIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        saveConfiguration(.toBudget, defaults: defaults)

        await CategoryFundingAutomation.process(
            savedTransactionId: "tx-1",
            using: store,
            defaults: defaults
        )

        #expect(store.error == nil)
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        let dining = try #require(month.categoryBudgets.first { $0.categoryId == "cat-dining" })
        #expect(dining.budgeted == 1000)
    }

    @Test("Unavailable funding category reports an actionable error")
    func unavailableFundingCategory() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        _ = try insertTransaction(in: database)

        let suiteName = "CategoryFundingAutomationIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        saveConfiguration(.category("missing-category"), defaults: defaults)

        await CategoryFundingAutomation.process(
            savedTransactionId: "tx-1",
            using: store,
            defaults: defaults
        )

        #expect(store.error?.contains("funding category is unavailable") == true)
    }

    @Test("Missing funding category is ignored when there is no shortfall")
    func missingFundingCategoryWithNoShortfallDoesNotError() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        _ = try insertTransaction(in: database, amount: -500)

        let suiteName = "CategoryFundingAutomationIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        saveConfiguration(.category("missing-category"), defaults: defaults)

        await CategoryFundingAutomation.process(
            savedTransactionId: "tx-1",
            using: store,
            defaults: defaults
        )

        #expect(store.error == nil)
    }

    @Test("A category cannot fund itself")
    func sameCategoryFundingDoesNotError() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        _ = try insertTransaction(in: database)

        let suiteName = "CategoryFundingAutomationIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        saveConfiguration(.category("cat-dining"), defaults: defaults)

        await CategoryFundingAutomation.process(
            savedTransactionId: "tx-1",
            using: store,
            defaults: defaults
        )

        #expect(store.error == nil)
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        let dining = try #require(month.categoryBudgets.first { $0.categoryId == "cat-dining" })
        #expect(dining.budgeted == 1000)
    }

    @Test("Income category cannot be used as a funding source")
    func incomeFundingCategoryIsRejected() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)
        _ = try insertTransaction(in: database)

        let suiteName = "CategoryFundingAutomationIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        saveConfiguration(.category("cat-income"), defaults: defaults)

        await CategoryFundingAutomation.process(
            savedTransactionId: "tx-1",
            using: store,
            defaults: defaults
        )

        #expect(store.error?.contains("funding category is unavailable") == true)
    }
}
