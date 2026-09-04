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

enum CategoryFundingDecision: Equatable {
    case none
    case fund(Int)
    case insufficientSource
    case invalidSource
    case sameSourceAndTarget
}

enum CategoryFundingAutomation {
    static func shortfall(transactionAmount: Int, availableAfterTransaction: Int) -> Int {
        guard transactionAmount < 0 else { return 0 }
        let expense = abs(transactionAmount)
        let availableBeforeTransaction = availableAfterTransaction - transactionAmount
        return max(0, expense - max(0, availableBeforeTransaction))
    }

    static func fundingDecision(
        transactionAmount: Int,
        availableAfterTransaction: Int,
        targetCategoryId: String? = nil,
        fundingSource: CategoryFundingSource,
        sourceAvailable: Int = 0,
        isTrackingBudget: Bool = false
    ) -> CategoryFundingDecision {
        let amount = shortfall(
            transactionAmount: transactionAmount,
            availableAfterTransaction: availableAfterTransaction
        )
        guard amount > 0 else { return .none }
        switch fundingSource {
        case .toBudget:
            return isTrackingBudget ? .invalidSource : .fund(amount)
        case .category(let sourceId):
            guard sourceId != targetCategoryId else { return .sameSourceAndTarget }
            return sourceAvailable >= amount ? .fund(amount) : .insufficientSource
        }
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

    @MainActor
    static func processIfNeeded(
        _ savedTransactionId: String?,
        using budgetStore: BudgetStore,
        defaults: UserDefaults = .standard
    ) {
        guard let savedTransactionId else { return }
        budgetStore.enqueueCategoryFunding(savedTransactionId: savedTransactionId, defaults: defaults)
    }

    @MainActor
    static func process(
        savedTransactionId: String,
        using budgetStore: BudgetStore,
        defaults: UserDefaults = .standard
    ) async {
        let processingBudgetId = budgetStore.currentBudgetId
        guard let processingBudgetId,
              let configuration = loadConfiguration(for: processingBudgetId, defaults: defaults),
              configuration.isEnabled,
              let selectedAccountId = configuration.accountId,
              let database = budgetStore.databaseForLogger else { return }
        guard let selectedAccount = budgetStore.accounts.first(where: { $0.id == selectedAccountId }),
              !selectedAccount.closed, !selectedAccount.offBudget else { return }

        let transaction: Transaction
        do {
            guard let fetched = try await database.fetchTransaction(id: savedTransactionId) else { return }
            transaction = fetched
        } catch {
            budgetStore.error = "Category funding automation couldn't verify the saved transaction: \(error.localizedDescription)"
            return
        }
        guard let targetCategory = budgetStore.categoryGroups.flatMap(\.categories)
            .first(where: { $0.id == transaction.categoryId }),
            shouldProcess(transaction, selectedAccountId: selectedAccountId, isIncomeCategory: targetCategory.isIncome) else { return }

        let month = String(format: "%04d-%02d", transaction.date / 10000, (transaction.date / 100) % 100)
        let budgetMonth: BudgetMonth
        do {
            budgetMonth = try await database.fetchBudgetMonth(month: month)
        } catch {
            budgetStore.error = "Category funding automation couldn't load the budget month: \(error.localizedDescription)"
            return
        }
        guard let category = budgetMonth.categoryBudgets.first(where: { $0.categoryId == transaction.categoryId }) else { return }

        let sourceCategoryId: String?
        let sourceAvailable: Int
        switch configuration.fundingSource {
        case .toBudget:
            sourceCategoryId = nil
            sourceAvailable = 0
        case .category(let sourceId):
            guard let sourceCategory = budgetMonth.categoryBudgets.first(where: { $0.categoryId == sourceId }) else {
                budgetStore.error = "Couldn't automatically fund \(category.categoryName): the selected funding category is unavailable."
                return
            }
            sourceCategoryId = sourceCategory.categoryId
            sourceAvailable = sourceCategory.available
        }

        switch fundingDecision(
            transactionAmount: transaction.amount,
            availableAfterTransaction: category.available,
            targetCategoryId: category.categoryId,
            fundingSource: configuration.fundingSource,
            sourceAvailable: sourceAvailable,
            isTrackingBudget: budgetMonth.isTrackingBudget
        ) {
        case .none, .sameSourceAndTarget:
            return
        case .invalidSource:
            budgetStore.error = "Couldn't automatically fund \(category.categoryName): To Budget is not available for tracking budgets. Choose a funding category."
        case .insufficientSource:
            budgetStore.error = "Couldn't automatically fund \(category.categoryName): the funding category doesn't have enough available."
        case .fund(let amount):
            guard budgetStore.currentBudgetId == processingBudgetId else { return }
            let displayedMonth = budgetStore.currentBudgetMonth?.month
            do {
                try await budgetStore.transferBudget(month: month, fromCategoryId: sourceCategoryId, toCategoryId: category.categoryId, amountCents: amount)
            } catch {
                budgetStore.error = "Couldn't automatically fund \(category.categoryName): \(error.localizedDescription)"
            }
            if let displayedMonth, displayedMonth != month {
                await budgetStore.fetchBudgetMonth(displayedMonth)
            }
        }
    }

    static func loadConfiguration(for budgetId: String?, defaults: UserDefaults = .standard) -> CategoryFundingAutomationConfiguration? {
        guard let budgetId, let data = defaults.data(forKey: key(for: budgetId)) else { return nil }
        return try? JSONDecoder().decode(CategoryFundingAutomationConfiguration.self, from: data)
    }

    static func saveConfiguration(_ configuration: CategoryFundingAutomationConfiguration, for budgetId: String?, defaults: UserDefaults = .standard) {
        guard let budgetId, let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key(for: budgetId))
    }

    private static func key(for budgetId: String) -> String { "categoryFundingAutomation_\(budgetId)" }
}