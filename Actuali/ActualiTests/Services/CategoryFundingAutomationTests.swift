import Testing

struct CategoryFundingAutomationTests {
    @Test("Sufficient category funds require no funding")
    func sufficientFunds() {
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -50, availableAfterTransaction: 50) == 0)
    }

    @Test("Partial category funds fund only the shortfall")
    func partialFunds() {
        // $20 was available before the $50 expense, so the post-transaction
        // available balance is -$30. Only $30 is funded.
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -50, availableAfterTransaction: -30) == 30)
    }

    @Test("Zero category funds fund the full transaction")
    func zeroFunds() {
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -50, availableAfterTransaction: -50) == 50)
    }

    @Test("Exact category balance requires no funding")
    func exactBalance() {
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -50, availableAfterTransaction: 0) == 0)
    }

    @Test("Existing overspending is preserved")
    func existingOverspending() {
        // The category was already -$500 before a new $50 expense. The new
        // transaction is funded by $50, leaving the category at -$500 rather
        // than funding the existing $500 deficit.
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -50, availableAfterTransaction: -550) == 50)
    }

    @Test("Existing overspending of any size only funds the new transaction")
    func largerExistingOverspending() {
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -125, availableAfterTransaction: -1000) == 125)
    }

    @Test("Positive available balance funds only the amount needed for the new transaction")
    func positiveBalanceShortfall() {
        // $20 available before a $50 expense means only $30 is needed.
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -50, availableAfterTransaction: -30) == 30)
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

    private func makeTransaction(
        accountId: String = "account-1",
        amount: Int = -5000,
        categoryId: String?,
        transferId: String? = nil
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
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )
    }
}
