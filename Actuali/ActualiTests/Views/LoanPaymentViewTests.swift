import Foundation
import Testing
@testable import Actuali

struct LoanPaymentViewTests {
    private func account(
        _ id: String,
        _ name: String,
        type: AccountType = .checking,
        offBudget: Bool = false,
        closed: Bool = false,
        sortOrder: Int = 0
    ) -> Account {
        Account(
            id: id, name: name, type: type, offBudget: offBudget,
            closed: closed, sortOrder: sortOrder, balance: 0
        )
    }

    // MARK: - Where the money comes from

    @Test func fundingAccountsAreOpenOnBudgetAndNotTheLoanItself() {
        let accounts = [
            account("acct_checking", "Checking"),
            account("acct_savings", "Savings", type: .savings, sortOrder: 1),
            account("acct_loan", "Car Loan", type: .debt, offBudget: true, sortOrder: 2),
            account("acct_closed", "Old Checking", closed: true, sortOrder: 3),
            account("acct_tracking", "Brokerage", type: .investment, offBudget: true, sortOrder: 4),
        ]

        let funding = LoanPaymentView.fundingAccounts(accounts, loanAccountId: "acct_loan")

        #expect(funding.map(\.id) == ["acct_checking", "acct_savings"])
    }

    /// Paying from another off-budget account would move money without
    /// touching the budget, which is the whole point of pairing a category.
    @Test func offBudgetAccountsCantFundAPayment() {
        let accounts = [account("acct_tracking", "Brokerage", type: .investment, offBudget: true)]

        #expect(LoanPaymentView.fundingAccounts(accounts, loanAccountId: "acct_loan").isEmpty)
    }

    @Test func fundingAccountsSortByPositionThenName() {
        let accounts = [
            account("b", "Zebra", sortOrder: 0),
            account("a", "Alpha", sortOrder: 1),
            account("c", "Beta", sortOrder: 0),
        ]

        let funding = LoanPaymentView.fundingAccounts(accounts, loanAccountId: "acct_loan")

        #expect(funding.map(\.name) == ["Beta", "Zebra", "Alpha"])
    }

    // MARK: - The breakdown

    @Test func principalIsWhatSurvivesInterestAndEscrow() {
        #expect(LoanPaymentView.principal(payment: 36500, interest: 11000, escrow: 0) == 25500)
        #expect(LoanPaymentView.principal(payment: 36500, interest: 11000, escrow: 20000) == 5500)
    }

    /// The view leans on this staying signed: a negative principal is what
    /// switches the footer to the warning that the balance will grow.
    @Test func principalGoesNegativeWhenThePaymentFallsShort() {
        #expect(LoanPaymentView.principal(payment: 5000, interest: 11000, escrow: 0) == -6000)
    }
}
