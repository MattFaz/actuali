import Foundation
import Combine

/// The pool used to cover a category shortfall. `toBudget` means money already
/// available in the budget pool; `category` moves money from another budget
/// category that has available funds.
enum CategoryFundingSource: Hashable, Codable, Identifiable {
    case toBudget
    case category(String)

    var id: String {
        switch self {
        case .toBudget: return "toBudget"
        case .category(let categoryId): return "category:\(categoryId)"
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if value == "toBudget" {
            self = .toBudget
        } else {
            self = .category(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .toBudget:
            try container.encode("toBudget")
        case .category(let categoryId):
            try container.encode(categoryId)
        }
    }
}

struct CategoryFundingAutomationConfiguration: Codable, Equatable {
    var isEnabled = false
    var accountId: String?
    /// Defaults to To Budget. When a category is selected, that category must
    /// have positive available funds at the time the automation runs.
    var fundingSource: CategoryFundingSource = .toBudget
}

enum CategoryFundingAutomation {
    /// Returns only the amount needed to cover the new expense. Existing
    /// overspending is intentionally preserved.
    ///
    /// Example: if a category is already at -$500 and a new $50 expense is
    /// posted, the category should receive $50, resulting in -$500 again.
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
}

@MainActor
final class CategoryFundingAutomationMonitor: ObservableObject {
    private var budgetId: String?
    private var hasBaseline = false
    private var seenTransactionIds = Set<String>()
    private var processingTransactionIds = Set<String>()

    func reset(for budgetId: String?) {
        guard self.budgetId != budgetId else { return }
        self.budgetId = budgetId
        hasBaseline = false
        seenTransactionIds.removeAll()
        processingTransactionIds.removeAll()
    }

    func processCurrentSnapshot(using budgetStore: BudgetStore) {
        reset(for: budgetStore.currentBudgetId)
        guard budgetStore.dataVersion > 0 else { return }

        guard !hasBaseline else {
            let newTransactions = budgetStore.transactions.filter { !seenTransactionIds.contains($0.id) }
            for transaction in newTransactions {
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

        seenTransactionIds = Set(budgetStore.transactions.map(\.id))
        hasBaseline = true
    }

    private func process(_ transaction: Transaction, using budgetStore: BudgetStore) async {
        guard let configuration = Self.loadConfiguration(for: budgetStore.currentBudgetId),
              configuration.isEnabled,
              let accountId = configuration.accountId,
              !processingTransactionIds.contains(transaction.id) else { return }

        let isIncomeCategory = budgetStore.categoryGroups
            .flatMap(\.categories)
            .first(where: { $0.id == transaction.categoryId })?
            .isIncome ?? false

        guard CategoryFundingAutomation.shouldProcess(
            transaction,
            selectedAccountId: accountId,
            isIncomeCategory: isIncomeCategory
        ) else { return }

        processingTransactionIds.insert(transaction.id)
        defer { processingTransactionIds.remove(transaction.id) }

        let month = String(format: "%04d-%02d", transaction.date / 10000, (transaction.date / 100) % 100)
        let displayedMonth = budgetStore.currentBudgetMonth?.month
        await budgetStore.fetchBudgetMonth(month)
        guard let category = budgetStore.currentBudgetMonth?.allCategoryBudgets.first(where: {
            $0.categoryId == transaction.categoryId
        }) else {
            if let displayedMonth, displayedMonth != month {
                await budgetStore.fetchBudgetMonth(displayedMonth)
            }
            return
        }

        let amountToFund = CategoryFundingAutomation.shortfall(
            transactionAmount: transaction.amount,
            availableAfterTransaction: category.available
        )
        guard amountToFund > 0 else {
            if let displayedMonth, displayedMonth != month {
                await budgetStore.fetchBudgetMonth(displayedMonth)
            }
            return
        }

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
                      let sourceCategory = budgetStore.currentBudgetMonth?.allCategoryBudgets.first(where: {
                          $0.categoryId == sourceCategoryId
                      }),
                      sourceCategory.available >= amountToFund else {
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

        if let displayedMonth, displayedMonth != month {
            await budgetStore.fetchBudgetMonth(displayedMonth)
        }
    }

    static func loadConfiguration(for budgetId: String?) -> CategoryFundingAutomationConfiguration? {
        guard let budgetId,
              let data = UserDefaults.standard.data(forKey: key(for: budgetId)) else {
            return nil
        }
        return try? JSONDecoder().decode(CategoryFundingAutomationConfiguration.self, from: data)
    }

    static func saveConfiguration(
        _ configuration: CategoryFundingAutomationConfiguration,
        for budgetId: String?
    ) {
        guard let budgetId,
              let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: key(for: budgetId))
    }

    private static func key(for budgetId: String) -> String {
        "categoryFundingAutomation_\(budgetId)"
    }
}
