import Foundation

/// Where a category shortfall is funded from.
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

@MainActor
private final class CategoryFundingProcessingQueue {
    private var pendingTask: Task<Void, Never>?
    private var generation = 0

    func enqueue(_ operation: @escaping @MainActor () async -> Void) async {
        generation += 1
        let currentGeneration = generation
        let previousTask = pendingTask
        let task = Task { @MainActor in
            if let previousTask {
                await previousTask.value
            }
            await operation()
        }
        pendingTask = task
        await task.value

        if generation == currentGeneration {
            pendingTask = nil
        }
    }
}

enum CategoryFundingAutomation {
    private static let processingQueue = CategoryFundingProcessingQueue()

    /// Existing overspending is intentionally preserved. The calculation only
    /// considers positive money that was available before the new expense.
    static func shortfall(transactionAmount: Int, availableAfterTransaction: Int) -> Int {
        guard transactionAmount < 0 else { return 0 }

        let expense = abs(transactionAmount)
        let availableBeforeTransaction = availableAfterTransaction - transactionAmount
        let usableFundsBeforeTransaction = max(0, availableBeforeTransaction)

        return max(0, expense - usableFundsBeforeTransaction)
    }

    /// Decide whether the configured source can cover the amount required by
    /// this new expense. To Budget may go negative; another category may not.
    static func fundingDecision(
        transactionAmount: Int,
        availableAfterTransaction: Int,
        targetCategoryId: String? = nil,
        fundingSource: CategoryFundingSource,
        sourceAvailable: Int? = nil,
        isTrackingBudget: Bool = false
    ) -> CategoryFundingDecision {
        let amount = shortfall(
            transactionAmount: transactionAmount,
            availableAfterTransaction: availableAfterTransaction
        )
        guard amount > 0 else { return .none }

        switch fundingSource {
        case .toBudget:
            guard !isTrackingBudget else { return .invalidSource }
            return .fund(amount)
        case .category(let sourceId):
            guard sourceId != targetCategoryId else { return .sameSourceAndTarget }
            guard let sourceAvailable else { return .invalidSource }
            return sourceAvailable >= amount ? .fund(amount) : .insufficientSource
        }
    }

    static func shouldProcess(
        _ transaction: Transaction,
        selectedAccountId: String,
        isIncomeCategory: Bool,
        isOffBudgetAccount: Bool = false
    ) -> Bool {
        transaction.accountId == selectedAccountId
            && !isOffBudgetAccount
            && transaction.amount < 0
            && transaction.categoryId != nil
            && !transaction.isParent
            && transaction.parentId == nil
            && transaction.transferId == nil
            && !isIncomeCategory
            && !transaction.tombstone
    }

    /// Runs only after a successful manual Add Transaction save. The id is the
    /// exact row created by the form, so backdated transactions, rows on other
    /// accounts, and newer rows elsewhere in the budget cannot be mistaken for
    /// the triggering transaction.
    @MainActor
    static func process(
        savedTransactionId: String,
        using budgetStore: BudgetStore,
        defaults: UserDefaults = .standard
    ) async {
        await processingQueue.enqueue {
            await processNow(
                savedTransactionId: savedTransactionId,
                using: budgetStore,
                defaults: defaults
            )
        }
    }

    @MainActor
    private static func processNow(
        savedTransactionId: String,
        using budgetStore: BudgetStore,
        defaults: UserDefaults
    ) async {
        guard let configuration = loadConfiguration(
            for: budgetStore.currentBudgetId,
            defaults: defaults
        ), configuration.isEnabled,
              let selectedAccountId = configuration.accountId,
              let database = budgetStore.databaseForLogger else {
            return
        }

        guard let selectedAccount = budgetStore.accounts.first(where: {
            $0.id == selectedAccountId
        }), !selectedAccount.closed, !selectedAccount.offBudget else {
            return
        }

        let transaction: Transaction
        do {
            guard let fetched = try await database.fetchTransaction(id: savedTransactionId) else {
                // A delete-transaction rule may legitimately remove the row.
                return
            }
            transaction = fetched
        } catch {
            budgetStore.error = "Category funding automation couldn't verify the saved transaction: \(error.localizedDescription)"
            return
        }

        let isIncomeCategory = budgetStore.categoryGroups
            .flatMap(\.categories)
            .first(where: { $0.id == transaction.categoryId })?
            .isIncome ?? false

        guard shouldProcess(
            transaction,
            selectedAccountId: selectedAccountId,
            isIncomeCategory: isIncomeCategory
        ) else { return }

        let month = String(
            format: "%04d-%02d",
            transaction.date / 10000,
            (transaction.date / 100) % 100
        )

        let budgetMonth: BudgetMonth
        do {
            budgetMonth = try await database.fetchBudgetMonth(month: month)
        } catch {
            budgetStore.error = "Category funding automation couldn't load the budget month: \(error.localizedDescription)"
            return
        }

        guard let category = budgetMonth.allCategoryBudgets.first(where: {
            $0.categoryId == transaction.categoryId
        }) else {
            return
        }

        let sourceCategoryId: String?
        let sourceAvailable: Int?
        switch configuration.fundingSource {
        case .toBudget:
            sourceCategoryId = nil
            sourceAvailable = nil
        case .category(let sourceId):
            guard let sourceCategory = budgetMonth.allCategoryBudgets.first(where: {
                $0.categoryId == sourceId
            }) else {
                budgetStore.error = "Couldn't automatically fund \(category.categoryName): the selected funding category is unavailable."
                return
            }

            guard sourceCategory.categoryId != category.categoryId else {
                budgetStore.error = "Couldn't automatically fund \(category.categoryName): choose a different funding category."
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
        case .none:
            return
        case .invalidSource:
            budgetStore.error = "Couldn't automatically fund \(category.categoryName): To Budget is not available for tracking budgets. Choose a funding category."
        case .insufficientSource:
            budgetStore.error = "Couldn't automatically fund \(category.categoryName): the funding category doesn't have enough available."
        case .sameSourceAndTarget:
            budgetStore.error = "Couldn't automatically fund \(category.categoryName): choose a different funding category."
        case .fund(let amountToFund):
            let displayedMonth = budgetStore.currentBudgetMonth?.month
            do {
                try await budgetStore.transferBudget(
                    month: month,
                    fromCategoryId: sourceCategoryId,
                    toCategoryId: category.categoryId,
                    amountCents: amountToFund
                )
            } catch {
                budgetStore.error = "Couldn't automatically fund \(category.categoryName): \(error.localizedDescription)"
            }

            // transferBudget refreshes the transaction's month. Restore the
            // month the user was viewing when the automation started.
            if let displayedMonth, displayedMonth != month {
                await budgetStore.fetchBudgetMonth(displayedMonth)
            }
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
