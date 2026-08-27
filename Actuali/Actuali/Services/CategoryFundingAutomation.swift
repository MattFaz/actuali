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

enum CategoryFundingAutomation {
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
        sourceAvailable: Int? = nil
    ) -> CategoryFundingDecision {
        let amount = shortfall(
            transactionAmount: transactionAmount,
            availableAfterTransaction: availableAfterTransaction
        )
        guard amount > 0 else { return .none }

        switch fundingSource {
        case .toBudget:
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

    /// Runs only after a successful manual Add Transaction save. The id is the
    /// exact row created by the form, so backdated transactions, rows on other
    /// accounts, and newer rows elsewhere in the budget cannot be mistaken for
    /// the triggering transaction. Rules have already run before this point,
    /// so the stored transaction is authoritative.
    @MainActor
    static func process(
        savedTransactionId: String,
        using budgetStore: BudgetStore,
        defaults: UserDefaults = .standard
    ) async {
        guard let configuration = loadConfiguration(
            for: budgetStore.currentBudgetId,
            defaults: defaults
        ), configuration.isEnabled,
              let selectedAccountId = configuration.accountId,
              let database = budgetStore.databaseForLogger,
              let transaction = try? await database.fetchTransaction(id: savedTransactionId) else {
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

        guard let budgetMonth = try? await database.fetchBudgetMonth(month: month),
              let category = budgetMonth.allCategoryBudgets.first(where: {
                  $0.categoryId == transaction.categoryId
              }) else {
            return
        }

        let sourceAvailable: Int?
        let sourceCategoryId: String?
        switch configuration.fundingSource {
        case .toBudget:
            sourceAvailable = nil
            sourceCategoryId = nil
        case .category(let sourceId):
            sourceCategoryId = sourceId
            sourceAvailable = budgetMonth.allCategoryBudgets.first(where: {
                $0.categoryId == sourceId
            })?.available
        }

        switch fundingDecision(
            transactionAmount: transaction.amount,
            availableAfterTransaction: category.available,
            targetCategoryId: category.categoryId,
            fundingSource: configuration.fundingSource,
            sourceAvailable: sourceAvailable
        ) {
        case .none:
            return
        case .invalidSource:
            budgetStore.error = "Couldn't fund \(category.categoryName): the selected funding category is unavailable."
        case .insufficientSource:
            budgetStore.error = "Couldn't fund \(category.categoryName): the funding category doesn't have enough available."
        case .sameSourceAndTarget:
            budgetStore.error = "Couldn't fund \(category.categoryName): choose a different funding category."
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

/// The existing BudgetStore save API returns Void. Manual category funding
/// needs the exact created id, so this narrow helper mirrors only the standard
/// expense-create path and leaves all existing edit/transfer/split behavior in
/// BudgetStore untouched.
extension BudgetStore {
    @discardableResult
    func createManualExpenseReturningID(_ form: TransactionForm) async throws -> String? {
        guard form.type == .expense, form.splits.isEmpty, !form.collapseSplit else {
            return nil
        }

        let date = Transaction.yyyymmdd(from: form.date)
        guard case .standard(let amountCents) = try Self.plan(for: form), amountCents < 0 else {
            return nil
        }

        let notes = form.notes.isEmpty ? nil : form.notes
        let payeeId = try await resolvePayeeId(name: form.payeeName, editing: nil)
        let payeeName = form.payeeName.isEmpty ? nil : form.payeeName
        let transaction = Transaction(
            id: UUID().uuidString,
            accountId: form.accountId,
            date: date,
            amount: amountCents,
            payeeId: payeeId,
            payeeName: payeeName,
            categoryId: form.categoryId,
            categoryName: nil,
            notes: notes,
            cleared: form.cleared,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: payeeName
        )

        try await createTransaction(transaction)
        if form.recordLocation, let payeeId {
            recordPayeeLocationIfAppropriate(payeeId: payeeId)
        }

        // A delete-transaction rule can remove the just-created row. Don't
        // hand a non-existent id to the funding automation in that case.
        guard let database = databaseForLogger,
              (try? await database.fetchTransaction(id: transaction.id)) != nil else {
            return nil
        }
        return transaction.id
    }
}