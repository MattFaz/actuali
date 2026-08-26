import Foundation

/// The pool used to cover a category shortfall. `toBudget` means money in the
/// budget pool; `category` moves money from another budget category.
enum CategoryFundingSource: Hashable, Codable {
    case toBudget
    case category(String)
}

struct CategoryFundingAutomationConfiguration: Codable, Equatable {
    var isEnabled = false
    var accountId: String?
    /// Defaults to To Budget. A category source is re-validated when the
    /// automation runs and must have enough available money for the shortfall.
    var fundingSource: CategoryFundingSource = .toBudget
}

enum CategoryFundingAutomation {
    /// Returns only the amount needed to cover the new expense. Existing
    /// overspending is intentionally preserved.
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

    /// Uncategorized transactions are deliberately left out of the seen set.
    /// They can therefore become eligible when the user assigns a category.
    static func shouldMarkSeen(_ transaction: Transaction) -> Bool {
        transaction.categoryId != nil || transaction.isParent
    }
}

@MainActor
final class CategoryFundingAutomationMonitor {
    private var budgetId: String?
    private var versionAtReset = 0
    private var hasBaseline = false
    private var seenTransactionIds = Set<String>()

    func reset(for budgetId: String?, dataVersion: Int) {
        guard self.budgetId != budgetId else { return }
        self.budgetId = budgetId
        versionAtReset = dataVersion
        hasBaseline = false
        seenTransactionIds.removeAll()
    }

    func processCurrentSnapshot(using budgetStore: BudgetStore) {
        reset(for: budgetStore.currentBudgetId, dataVersion: budgetStore.dataVersion)
        guard budgetStore.dataVersion > versionAtReset else { return }

        guard !hasBaseline else {
            let newTransactions = budgetStore.transactions.filter {
                !seenTransactionIds.contains($0.id)
            }

            for transaction in newTransactions where CategoryFundingAutomation.shouldMarkSeen(transaction) {
                seenTransactionIds.insert(transaction.id)
            }

            guard !newTransactions.isEmpty else { return }
            Task { [weak self, weak budgetStore] in
                guard let self, let budgetStore else { return }
                for transaction in newTransactions {
                    await self.process(transaction, using: budgetStore)
                }
            }
            return
        }

        seenTransactionIds = Set(
            budgetStore.transactions.compactMap { transaction in
                CategoryFundingAutomation.shouldMarkSeen(transaction) ? transaction.id : nil
            }
        )
        hasBaseline = true
    }

    private func process(_ transaction: Transaction, using budgetStore: BudgetStore) async {
        guard let configuration = Self.loadConfiguration(for: budgetStore.currentBudgetId),
              configuration.isEnabled,
              let accountId = configuration.accountId else { return }

        let isIncomeCategory = budgetStore.categoryGroups
            .flatMap(\.categories)
            .first(where: { $0.id == transaction.categoryId })?
            .isIncome ?? false

        guard CategoryFundingAutomation.shouldProcess(
            transaction,
            selectedAccountId: accountId,
            isIncomeCategory: isIncomeCategory
        ) else { return }

        let month = String(format: "%04d-%02d", transaction.date / 10000, (transaction.date / 100) % 100)
        let displayedMonth = budgetStore.currentBudgetMonth?.month
        await budgetStore.fetchBudgetMonth(month)
        guard let category = budgetStore.currentBudgetMonth?.allCategoryBudgets.first(where: {
            $0.categoryId == transaction.categoryId
        }) else {
            restoreDisplayedMonth(displayedMonth, transactionMonth: month, using: budgetStore)
            return
        }

        let amountToFund = CategoryFundingAutomation.shortfall(
            transactionAmount: transaction.amount,
            availableAfterTransaction: category.available
        )
        guard amountToFund > 0 else {
            restoreDisplayedMonth(displayedMonth, transactionMonth: month, using: budgetStore)
            return
        }

        do {
            switch configuration.fundingSource {
            case .toBudget:
                // To Budget is allowed to become negative in Actuali, so it
                // can always provide the requested shortfall.
                try await budgetStore.transferBudget(
                    month: month,
                    fromCategoryId: nil,
                    toCategoryId: category.categoryId,
                    amountCents: amountToFund
                )

            case .category(let sourceCategoryId):
                guard sourceCategoryId != category.categoryId,
                      let sourceCategory = budgetStore.currentBudgetMonth?.allCategoryBudgets.first(where: {
                          $0.categoryId == sourceCategoryId
                      }) else {
                    budgetStore.error = "Couldn't fund \(category.categoryName): the selected funding category is unavailable."
                    restoreDisplayedMonth(displayedMonth, transactionMonth: month, using: budgetStore)
                    return
                }

                guard sourceCategory.available >= amountToFund else {
                    budgetStore.error = "Couldn't fund \(category.categoryName): the funding category doesn't have enough available."
                    restoreDisplayedMonth(displayedMonth, transactionMonth: month, using: budgetStore)
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

        restoreDisplayedMonth(displayedMonth, transactionMonth: month, using: budgetStore)
    }

    private func restoreDisplayedMonth(
        _ displayedMonth: String?,
        transactionMonth: String,
        using budgetStore: BudgetStore
    ) {
        guard let displayedMonth, displayedMonth != transactionMonth else { return }
        Task { @MainActor in
            await budgetStore.fetchBudgetMonth(displayedMonth)
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
