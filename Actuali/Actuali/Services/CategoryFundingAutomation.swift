import Foundation

enum CategoryFundingSource: Hashable, Codable {
    case toBudget
    case category(String)
}

struct CategoryFundingAutomationConfiguration: Codable, Equatable {
    var isEnabled = false
    var accountId: String?
    var fundingSource: CategoryFundingSource = .toBudget
}

enum CategoryFundingAutomation {
    static func shortfall(transactionAmount: Int, availableAfterTransaction: Int) -> Int {
        guard transactionAmount < 0 else { return 0 }

        let expense = abs(transactionAmount)
        let availableBeforeTransaction = availableAfterTransaction - transactionAmount
        let usableFundsBeforeTransaction = max(0, availableBeforeTransaction)

        return max(0, expense - usableFundsBeforeTransaction)
    }

    static func shouldProcess(
        _ transaction: Transaction,
        selectedAccountId: String,
        isIncomeCategory: Bool
    ) -> Bool {
        transaction.accountId == selectedAccountId
            && transaction.amount < 0
            && transaction.categoryId != nil
            && !transaction.isParent
            && transaction.parentId == nil
            && transaction.transferId == nil
            && !isIncomeCategory
            && !transaction.tombstone
    }

    static func isManualExpenseEligible(
        _ transaction: Transaction,
        selectedAccountId: String,
        isIncomeCategory: Bool
    ) -> Bool {
        shouldProcess(
            transaction,
            selectedAccountId: selectedAccountId,
            isIncomeCategory: isIncomeCategory
        )
    }

    /// Called explicitly after a successful manual Add Transaction save.
    /// Imported, synced, scheduled, duplicated, and edited transactions do not
    /// invoke this automation.
    @MainActor
    static func processManualTransaction(
        accountId: String,
        using budgetStore: BudgetStore
    ) async {
        guard let configuration = loadConfiguration(for: budgetStore.currentBudgetId),
              configuration.isEnabled,
              configuration.accountId == accountId else { return }

        // AddTransactionView refreshes the store after a successful save. The
        // newly-created row has the newest sort order for this account.
        guard let transaction = budgetStore.transactions
            .filter({ $0.accountId == accountId && !$0.tombstone })
            .max(by: { lhs, rhs in
                (lhs.sortOrder ?? 0) < (rhs.sortOrder ?? 0)
            }) else { return }

        let isIncomeCategory = budgetStore.categoryGroups
            .flatMap(\.categories)
            .first(where: { $0.id == transaction.categoryId })?
            .isIncome ?? false

        guard isManualExpenseEligible(
            transaction,
            selectedAccountId: accountId,
            isIncomeCategory: isIncomeCategory
        ) else { return }

        let month = String(
            format: "%04d-%02d",
            transaction.date / 10000,
            (transaction.date / 100) % 100
        )

        // Read the budget month directly from the database so the automation
        // never changes the month the Budget tab is displaying.
        guard let database = budgetStore.databaseForLogger,
              let budgetMonth = try? await database.fetchBudgetMonth(month: month),
              let category = budgetMonth.allCategoryBudgets.first(where: {
                  $0.categoryId == transaction.categoryId
              }) else { return }

        let amountToFund = shortfall(
            transactionAmount: transaction.amount,
            availableAfterTransaction: category.available
        )
        guard amountToFund > 0 else { return }

        do {
            switch configuration.fundingSource {
            case .toBudget:
                try await budgetStore.transferBudget(
                    month: month,
                    fromCategoryId: nil,
                    toCategoryId: category.categoryId,
                    amountCents: amountToFund
                )

            case .category(let sourceCategoryId):
                guard sourceCategoryId != category.categoryId,
                      let sourceCategory = budgetMonth.allCategoryBudgets.first(where: {
                          $0.categoryId == sourceCategoryId
                      }) else {
                    budgetStore.error = "Couldn't fund \(category.categoryName): the selected funding category is unavailable."
                    return
                }

                // A category source must cover the complete shortfall. Never
                // partially drain it and leave the user with an unexplained
                // remaining shortfall.
                guard sourceCategory.available >= amountToFund else {
                    budgetStore.error = "Couldn't fund \(category.categoryName): the funding category doesn't have enough available."
                    return
                }

                try await budgetStore.transferBudget(
                    month: month,
                    fromCategoryId: sourceCategoryId,
                    toCategoryId: category.categoryId,
                    amountCents: amountToFund
                )
            }
        } catch {
            budgetStore.error = "Couldn't automatically fund \(category.categoryName): \(error.localizedDescription)"
        }
    }

    static func loadConfiguration(
        for budgetId: String?,
        defaults: UserDefaults = .standard
    ) -> CategoryFundingAutomationConfiguration? {
        guard let budgetId,
              let data = defaults.data(forKey: key(for: budgetId)) else {
            return nil
        }
        return try? JSONDecoder().decode(CategoryFundingAutomationConfiguration.self, from: data)
    }

    static func saveConfiguration(
        _ configuration: CategoryFundingAutomationConfiguration,
        for budgetId: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let budgetId,
              let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key(for: budgetId))
    }

    private static func key(for budgetId: String) -> String {
        "categoryFundingAutomation_\(budgetId)"
    }
}
