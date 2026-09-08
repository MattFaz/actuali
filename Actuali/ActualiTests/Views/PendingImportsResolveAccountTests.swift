import Foundation
import Testing
@testable import Actuali

/// Covers `PendingImportApprover.seedAccountId` — the edit form's account seed
/// chain: strict hint resolution, then default account, then first open
/// account. The strict matcher itself is covered by
/// `BudgetStoreAccountMappingTests`.
struct PendingImportsResolveAccountTests {

    private let appBundle = Bundle(identifier: "com.mfazz.ActualiOS")!

    @Test func approvalFailureMessageInterpolatesTheCount() {
        #expect(PendingImportsView.approvalFailureMessage(
            count: 0, locale: Locale(identifier: "en_US"), bundle: appBundle)
            == "0 transactions could not be approved. Please check their details.")
        #expect(PendingImportsView.approvalFailureMessage(
            count: 1, locale: Locale(identifier: "en_US"), bundle: appBundle)
            == "1 transaction could not be approved. Please check its details.")
        #expect(PendingImportsView.approvalFailureMessage(
            count: 2, locale: Locale(identifier: "en_US"), bundle: appBundle)
            == "2 transactions could not be approved. Please check their details.")
        #expect(PendingImportsView.approvalFailureMessage(
            count: 2, locale: Locale(identifier: "fr_FR"), bundle: appBundle)
            == "2 transactions n’ont pas pu être approuvées. Vérifiez leurs détails.")
    }

    @Test func bulkApprovalFailuresRecoverConsistently() {
        #expect(PendingImportsView.bulkApprovalDisposition(
            for: PendingImportApprover.ApproveError.alreadyApproved
        ) == .removePendingImport)
        #expect(PendingImportsView.bulkApprovalDisposition(
            for: PendingImportApprover.ApproveError.noAccountAvailable
        ) == .review)
        #expect(PendingImportsView.bulkApprovalDisposition(
            for: PendingImportApprover.ApproveError.sourceCurrencyRequired
        ) == .review)
        #expect(PendingImportsView.bulkApprovalDisposition(
            for: PendingImportApprover.ApproveError.writeFailed("disk full")
        ) == .failure)
    }

    private func account(_ id: String, _ name: String, closed: Bool = false) -> Account {
        Account(id: id, name: name, type: .checking, offBudget: false, closed: closed,
                sortOrder: 0, balance: 0)
    }

    @Test func resolvesViaCardMapping() {
        let accounts = [account("acct_cash", "Cash"), account("acct_hsbc", "HSBC")]

        let result = PendingImportApprover.seedAccountId(
            cardHint: "1234", accounts: accounts,
            cardMappings: ["1234": "acct_hsbc"], defaultAccountId: nil)
        #expect(result == "acct_hsbc")
    }

    @Test func mappingBeatsDefaultAccount() {
        let accounts = [account("acct_cash", "Cash"), account("acct_hsbc", "HSBC")]

        let result = PendingImportApprover.seedAccountId(
            cardHint: "1234", accounts: accounts,
            cardMappings: ["1234": "acct_hsbc"], defaultAccountId: "acct_cash")
        #expect(result == "acct_hsbc")
    }

    @Test func unmatchedHintFallsBackToDefaultAccount() {
        let accounts = [account("acct_cash", "Cash"), account("acct_hsbc", "HSBC")]

        let result = PendingImportApprover.seedAccountId(
            cardHint: "9999", accounts: accounts,
            cardMappings: [:], defaultAccountId: "acct_hsbc")
        #expect(result == "acct_hsbc")
    }

    @Test func missingHintFallsBackToDefaultAccount() {
        let accounts = [account("acct_cash", "Cash"), account("acct_hsbc", "HSBC")]

        let result = PendingImportApprover.seedAccountId(
            cardHint: nil, accounts: accounts,
            cardMappings: [:], defaultAccountId: "acct_hsbc")
        #expect(result == "acct_hsbc")
    }

    @Test func mappingToClosedAccountFallsThrough() {
        // The strict resolver must skip a mapping that points at a closed
        // account; the seed chain then lands on the first open account.
        let accounts = [account("acct_old", "Old Card", closed: true), account("acct_cash", "Cash")]

        let result = PendingImportApprover.seedAccountId(
            cardHint: "1234", accounts: accounts,
            cardMappings: ["1234": "acct_old"], defaultAccountId: nil)
        #expect(result == "acct_cash")
    }

    @Test func closedDefaultFallsBackToFirstOpenAccount() {
        let accounts = [account("acct_old", "Old", closed: true), account("acct_cash", "Cash")]

        let result = PendingImportApprover.seedAccountId(
            cardHint: nil, accounts: accounts,
            cardMappings: [:], defaultAccountId: "acct_old")
        #expect(result == "acct_cash")
    }

    @Test func noDefaultFallsBackToFirstOpenAccount() {
        let accounts = [account("acct_cash", "Cash"), account("acct_hsbc", "HSBC")]

        let result = PendingImportApprover.seedAccountId(
            cardHint: nil, accounts: accounts,
            cardMappings: [:], defaultAccountId: nil)
        #expect(result == "acct_cash")
    }

    @Test func returnsNilOnlyWhenNoOpenAccounts() {
        let accounts = [account("acct_old", "Old", closed: true)]

        let result = PendingImportApprover.seedAccountId(
            cardHint: "1234", accounts: accounts,
            cardMappings: ["1234": "acct_old"], defaultAccountId: "acct_old")
        #expect(result == nil)
    }

    // MARK: - Regression: the exact scenario from the bug report

    @Test func resolvesMappedCardHintInsteadOfFirstAccount() {
        // "Spent 300 via 1234 hsbc at AWS m on 15th Aug 2026"
        // Parser extracts cardHint "1234", mapping routes to HSBC.
        // Before the fix: fell through to Cash (first account).
        let accounts = [account("acct_cash", "Cash"), account("acct_hsbc", "HSBC")]

        let result = PendingImportApprover.seedAccountId(
            cardHint: "1234", accounts: accounts,
            cardMappings: ["1234": "acct_hsbc"], defaultAccountId: nil)
        #expect(result == "acct_hsbc")
    }

    @Test func approvalUsesStrictRoutingWhileEditorKeepsFirstOpenFallback() {
        let accounts = [account("acct_old", "Closed", closed: true), account("acct_cash", "Cash")]

        let result = PendingImportApprover.resolveAccountId(
            cardHint: "unknown", accounts: accounts,
            cardMappings: [:], defaultAccountId: nil)

        #expect(result == nil)
        #expect(PendingImportApprover.seedAccountId(
            cardHint: "unknown", accounts: accounts,
            cardMappings: [:], defaultAccountId: nil
        ) == "acct_cash")
    }

    @Test func legacyImportUsesReviewSeedForExplicitAdoption() {
        let legacy = PendingImport(amount: 25, payee: "Coffee")
        let accounts = [account("acct_cash", "Cash")]

        // A legacy record cannot be directly approved; opening the editor and
        // saving is the explicit adoption action into the active budget.
        #expect(legacy.originBudgetId == nil)
        #expect(PendingImportApprover.seedAccountId(
            cardHint: legacy.cardHint,
            accounts: accounts,
            cardMappings: [:],
            defaultAccountId: nil
        ) == "acct_cash")
    }

    @Test func combinedReviewRequiresBothAcknowledgementsInOrder() {
        let item = PendingImport(originBudgetId: "foreign-budget", sourceCurrencyCode: "EUR")
        let requirements = item.reviewRequirements(activeBudgetId: "active-budget", budgetCurrency: "USD")

        #expect(requirements == [
            .adoptIntoActiveBudget,
            .confirmActiveBudgetCurrency(source: "EUR", budget: "USD")
        ])
        #expect(requirements.count == 2)
        #expect(requirements[1].prompt.contains("no conversion"))
    }

    @Test func unknownCurrencyRequiresIndependentAcknowledgement() {
        let currency = PendingImportReviewRequirement.confirmActiveBudgetCurrency(source: nil, budget: "USD")

        #expect(PendingImport(originBudgetId: "active-budget").reviewRequirements(
            activeBudgetId: "active-budget",
            budgetCurrency: "USD"
        ) == [currency])
        #expect(PendingImport().reviewRequirements(
            activeBudgetId: "active-budget",
            budgetCurrency: "USD"
        ) == [.adoptIntoActiveBudget, currency])
    }

    @Test func amountUsesBudgetCurrencyAndLocale() {
        #expect(PendingImportsView.amountString(
            1234.5, isIncome: false, currencyCode: "USD", sourceCurrencyCode: "EUR", narrowSymbol: false,
            numberFormat: .dotComma, locale: Locale(identifier: "de_DE")) == "-1.234,50 €")
        #expect(PendingImportsView.amountString(
            12.34, isIncome: false, currencyCode: "USD", sourceCurrencyCode: "EUR", narrowSymbol: false,
            numberFormat: .dotComma, locale: Locale(identifier: "de_DE")) == "-12,34 €")
        #expect(PendingImportsView.amountString(
            12.34, isIncome: true, currencyCode: "EUR", sourceCurrencyCode: "USD", narrowSymbol: true,
            numberFormat: .commaDot, locale: Locale(identifier: "en_US")) == "$12.34")
        #expect(PendingImportsView.amountString(
            12.34, isIncome: false, currencyCode: "USD", sourceCurrencyCode: nil, narrowSymbol: false,
            numberFormat: .commaDot, locale: Locale(identifier: "en_US")) == "-$12.34")
        #expect(PendingImportsView.amountString(
            1234.5, isIncome: false, currencyCode: "USD", sourceCurrencyCode: nil, narrowSymbol: false,
            numberFormat: .dotComma, locale: Locale(identifier: "en_US")) == "-$1.234,50")
    }

    @Test func bulkApprovalOutcomeDefersFailuresWhenReviewIsNeeded() {
        let item = PendingImport(amount: 1)
        #expect(PendingImportsView.bulkApprovalOutcome(reviewItem: item, failedCount: 0)
            == .review(deferredFailureCount: 0))
        #expect(PendingImportsView.bulkApprovalOutcome(reviewItem: item, failedCount: 2)
            == .review(deferredFailureCount: 2))
        #expect(PendingImportsView.bulkApprovalOutcome(reviewItem: nil, failedCount: 2)
            == .failure(count: 2))
        #expect(PendingImportsView.bulkApprovalOutcome(reviewItem: nil, failedCount: 0)
            == .none)
    }
}
