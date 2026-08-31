import Foundation
import Testing
@testable import Actuali

struct CategoryFundingAutomationTests {
    @Test("Sufficient category funds require no funding")
    func sufficientFunds() {
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -50, availableAfterTransaction: 50) == 0)
        #expect(CategoryFundingAutomation.fundingDecision(
            transactionAmount: -50,
            availableAfterTransaction: 50,
            fundingSource: .toBudget
        ) == .none)
    }

    @Test("Partial category funds fund only the shortfall")
    func partialFunds() {
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -50, availableAfterTransaction: -30) == 30)
        #expect(CategoryFundingAutomation.fundingDecision(
            transactionAmount: -50,
            availableAfterTransaction: -30,
            fundingSource: .toBudget
        ) == .fund(30))
    }

    @Test("Zero category funds fund the full transaction")
    func zeroFunds() {
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -50, availableAfterTransaction: -50) == 50)
        #expect(CategoryFundingAutomation.fundingDecision(
            transactionAmount: -50,
            availableAfterTransaction: -50,
            fundingSource: .toBudget
        ) == .fund(50))
    }

    @Test("Exact category balance requires no funding")
    func exactBalance() {
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -50, availableAfterTransaction: 0) == 0)
        #expect(CategoryFundingAutomation.fundingDecision(
            transactionAmount: -50,
            availableAfterTransaction: 0,
            fundingSource: .category("emergency-fund"),
            sourceAvailable: 50
        ) == .none)
    }

    @Test("Existing overspending is preserved")
    func existingOverspending() {
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -50, availableAfterTransaction: -550) == 50)
        #expect(CategoryFundingAutomation.fundingDecision(
            transactionAmount: -50,
            availableAfterTransaction: -550,
            fundingSource: .toBudget
        ) == .fund(50))
    }

    @Test("Existing overspending of any size only funds the new transaction")
    func largerExistingOverspending() {
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -125, availableAfterTransaction: -1000) == 125)
    }

    @Test("Category funding source with enough money funds the complete shortfall")
    func categorySourceSufficient() {
        #expect(CategoryFundingAutomation.fundingDecision(
            transactionAmount: -50,
            availableAfterTransaction: -30,
            targetCategoryId: "groceries",
            fundingSource: .category("emergency-fund"),
            sourceAvailable: 30
        ) == .fund(30))
    }

    @Test("Category funding source cannot be partially drained")
    func categorySourceInsufficient() {
        #expect(CategoryFundingAutomation.fundingDecision(
            transactionAmount: -50,
            availableAfterTransaction: -30,
            targetCategoryId: "groceries",
            fundingSource: .category("emergency-fund"),
            sourceAvailable: 20
        ) == .insufficientSource)
    }

    @Test("Missing category funding source is reported as invalid")
    func categorySourceMissing() {
        #expect(CategoryFundingAutomation.fundingDecision(
            transactionAmount: -50,
            availableAfterTransaction: -50,
            targetCategoryId: "groceries",
            fundingSource: .category("emergency-fund"),
            sourceAvailable: nil
        ) == .invalidSource)
    }

    @Test("A category cannot fund itself")
    func sameSourceAndTargetIsInvalid() {
        #expect(CategoryFundingAutomation.fundingDecision(
            transactionAmount: -50,
            availableAfterTransaction: -50,
            targetCategoryId: "groceries",
            fundingSource: .category("groceries"),
            sourceAvailable: 100
        ) == .sameSourceAndTarget)
    }

    @Test("To Budget can fund even when its balance is negative")
    func negativeToBudget() {
        #expect(CategoryFundingAutomation.fundingDecision(
            transactionAmount: -50,
            availableAfterTransaction: -50,
            fundingSource: .toBudget
        ) == .fund(50))
    }

    @Test("To Budget is invalid for tracking budgets when a shortfall exists")
    func toBudgetIsInvalidForTrackingBudget() {
        #expect(CategoryFundingAutomation.fundingDecision(
            transactionAmount: -50,
            availableAfterTransaction: -50,
            fundingSource: .toBudget,
            isTrackingBudget: true
        ) == .invalidSource)
    }

    @Test("A tracking budget with no shortfall does not need a funding source")
    func trackingBudgetWithNoShortfallNeedsNoFunding() {
        #expect(CategoryFundingAutomation.fundingDecision(
            transactionAmount: -50,
            availableAfterTransaction: 25,
            fundingSource: .toBudget,
            isTrackingBudget: true
        ) == .none)
    }

    @Test("Zero-amount expense remains a valid standard transaction")
    @MainActor
    func zeroAmountExpensePlan() throws {
        let form = BudgetStore.TransactionForm(
            accountId: "account-1",
            type: .expense,
            amount: "0",
            payeeName: "Corner Shop",
            transferToAccountId: nil,
            categoryId: "groceries",
            notes: "",
            date: Date(),
            cleared: false
        )

        #expect(try BudgetStore.plan(for: form) == .standard(amountCents: 0))
    }

    @Test("Manual expense from selected on-budget account is eligible")
    func manualExpenseIsEligible() {
        let transaction = makeTransaction(categoryId: "groceries")
        #expect(CategoryFundingAutomation.shouldProcess(
            transaction,
            selectedAccountId: "account-1",
            isIncomeCategory: false,
            isOffBudgetAccount: false
        ))
    }

    @Test("Off-budget account transactions are ignored")
    func offBudgetAccount() {
        let transaction = makeTransaction(categoryId: "groceries")
        #expect(!CategoryFundingAutomation.shouldProcess(
            transaction,
            selectedAccountId: "account-1",
            isIncomeCategory: false,
            isOffBudgetAccount: true
        ))
    }

    @Test("Uncategorized transactions are ignored")
    func uncategorized() {
        let transaction = makeTransaction(categoryId: nil)
        #expect(!CategoryFundingAutomation.shouldProcess(
            transaction,
            selectedAccountId: "account-1",
            isIncomeCategory: false
        ))
    }

    @Test("Transactions from another account are ignored")
    func nonSelectedAccount() {
        let transaction = makeTransaction(accountId: "account-2", categoryId: "groceries")
        #expect(!CategoryFundingAutomation.shouldProcess(
            transaction,
            selectedAccountId: "account-1",
            isIncomeCategory: false
        ))
    }

    @Test("Income transactions are ignored")
    func income() {
        let transaction = makeTransaction(amount: 5000, categoryId: "income")
        #expect(!CategoryFundingAutomation.shouldProcess(
            transaction,
            selectedAccountId: "account-1",
            isIncomeCategory: true
        ))
    }

    @Test("Transfers are ignored")
    func transfer() {
        let transaction = makeTransaction(categoryId: "groceries", transferId: "other-leg")
        #expect(!CategoryFundingAutomation.shouldProcess(
            transaction,
            selectedAccountId: "account-1",
            isIncomeCategory: false
        ))
    }

    @Test("Non-expense amounts are ignored")
    func nonExpense() {
        let transaction = makeTransaction(amount: 1000, categoryId: "groceries")
        #expect(!CategoryFundingAutomation.shouldProcess(
            transaction,
            selectedAccountId: "account-1",
            isIncomeCategory: false
        ))
    }

    @Test("Split parents are ignored")
    func splitParent() {
        let transaction = makeTransaction(categoryId: nil, isParent: true)
        #expect(!CategoryFundingAutomation.shouldProcess(
            transaction,
            selectedAccountId: "account-1",
            isIncomeCategory: false
        ))
    }

    @Test("Deleted transactions are ignored")
    func deletedTransaction() {
        var transaction = makeTransaction(categoryId: "groceries")
        transaction.tombstone = true
        #expect(!CategoryFundingAutomation.shouldProcess(
            transaction,
            selectedAccountId: "account-1",
            isIncomeCategory: false
        ))
    }

    @Test("Category funding source round trips through Codable")
    func fundingSourceCodable() throws {
        let configuration = CategoryFundingAutomationConfiguration(
            isEnabled: true,
            accountId: "account-1",
            fundingSource: .category("emergency-fund")
        )

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(CategoryFundingAutomationConfiguration.self, from: data)

        #expect(decoded == configuration)
    }

    @Test("Configuration can be saved and loaded with injected UserDefaults")
    func configurationPersistence() {
        let suiteName = "CategoryFundingAutomationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = CategoryFundingAutomationConfiguration(
            isEnabled: true,
            accountId: "account-1",
            fundingSource: .category("emergency-fund")
        )

        CategoryFundingAutomation.saveConfiguration(
            configuration,
            for: "budget-1",
            defaults: defaults
        )

        #expect(
            CategoryFundingAutomation.loadConfiguration(
                for: "budget-1",
                defaults: defaults
            ) == configuration
        )
    }

    @Test("Default funding source is To Budget")
    func defaultFundingSource() {
        #expect(CategoryFundingAutomationConfiguration().fundingSource == .toBudget)
    }

    private func makeTransaction(
        accountId: String = "account-1",
        amount: Int = -5000,
        categoryId: String?,
        transferId: String? = nil,
        isParent: Bool = false
    ) -> Transaction {
        Transaction(
            id: UUID().uuidString,
            accountId: accountId,
            date: 20260825,
            amount: amount,
            payeeId: nil,
            payeeName: nil,
            categoryId: categoryId,
            categoryName: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            transferId: transferId,
            isParent: isParent,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )
    }
}
