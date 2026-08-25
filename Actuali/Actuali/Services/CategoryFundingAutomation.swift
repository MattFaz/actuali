import Foundation
import Combine

/// The pool used to cover a category shortfall.
///
/// `toBudget` is intentionally the only source for this first version. Keeping
/// the source as an enum makes the persisted setting explicit and leaves room
/// for category-to-category funding later without changing the trigger model.
enum CategoryFundingSource: String, Codable, CaseIterable, Identifiable {
    case toBudget

    var id: Self { self }

    var label: String {
        switch self {
        case .toBudget: return "To Budget"
        }
    }
}

struct CategoryFundingAutomationConfiguration: Codable, Equatable {
    var isEnabled = false
    var accountId: String?
    var fundingSource: CategoryFundingSource = .toBudget
}

/// Pure rules for deciding whether a newly-created transaction is eligible for
/// category funding. The monitor performs the database/budget work separately.
enum CategoryFundingAutomation {
    /// The category's available amount after the transaction has been inserted
    /// can be used to reconstruct the amount that was available immediately
    /// before it. This keeps the trigger correct even though Actuali refreshes
    /// its budget after a transaction write.
    static func shortfall(transactionAmount: Int, availableAfterTransaction: Int) -> Int {
        guard transactionAmount < 0 else { return 0 }
        let availableBeforeTransaction = availableAfterTransaction - transactionAmount
        return max(0, abs(transactionAmount) - availableBeforeTransaction)
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

/// Watches the store's published transaction snapshot for newly-created rows.
/// This deliberately sits above the transaction write paths so manual entry,
/// bank sync, Wallet imports, Shortcuts, and scheduled postings all use the
/// same automation without creating a second transaction pipeline.
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

        // The first snapshot after a budget load is history, not automation
        // input. Opening a budget must never retroactively fund old
        // transactions. This also correctly baselines an empty budget.
        seenTransactionIds = Set(budgetStore.transactions.map(\.id))
        hasBaseline = true
    }

    private func process(_ transaction: Transaction, using budgetStore: BudgetStore) async {
        guard let configuration = Self.loadConfiguration(for: budgetStore.currentBudgetId),
              configuration.isEnabled,
              let accountId = configuration.accountId,
              configuration.fundingSource == .toBudget,
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

        if amountToFund > 0 {
            do {
                try await budgetStore.transferBudget(
                    month: month,
                    fromCategoryId: nil,
                    toCategoryId: category.categoryId,
                    amountCents: amountToFund
                )
            } catch {
                // The transaction itself is already saved. Funding is a
                // follow-up automation, so a failed budget write must not undo
                // or duplicate the transaction.
                budgetStore.error = "Couldn't automatically fund \(category.categoryName): \(error.localizedDescription)"
            }
        }

        // `fetchBudgetMonth` temporarily changed the displayed month when the
        // transaction belongs to a historical month. Restore the user's view.
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
