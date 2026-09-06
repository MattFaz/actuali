import Foundation
import Testing
@testable import Actuali

/// Covers `PendingImportsView.seedAccountId` — the edit form's account seed
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

    @Test func reviewRequiredMessageIsDistinct() {
        #expect(PendingImportsView.reviewRequiredMessage(
            count: 2, locale: Locale(identifier: "en_US"), bundle: appBundle)
            == "2 transactions require review and were left pending.")
    }

    private func account(_ id: String, _ name: String, closed: Bool = false) -> Account {
        Account(id: id, name: name, type: .checking, offBudget: false, closed: closed,
                sortOrder: 0, balance: 0)
    }

    @Test func resolvesViaCardMapping() {
        let accounts = [account("acct_cash", "Cash"), account("acct_hsbc", "HSBC")]

        let result = PendingImportsView.seedAccountId(
            cardHint: "1234", accounts: accounts,
            cardMappings: ["1234": "acct_hsbc"], defaultAccountId: nil)
        #expect(result == "acct_hsbc")
    }

    @Test func mappingBeatsDefaultAccount() {
        let accounts = [account("acct_cash", "Cash"), account("acct_hsbc", "HSBC")]

        let result = PendingImportsView.seedAccountId(
            cardHint: "1234", accounts: accounts,
            cardMappings: ["1234": "acct_hsbc"], defaultAccountId: "acct_cash")
        #expect(result == "acct_hsbc")
    }

    @Test func unmatchedHintFallsBackToDefaultAccount() {
        let accounts = [account("acct_cash", "Cash"), account("acct_hsbc", "HSBC")]

        let result = PendingImportsView.seedAccountId(
            cardHint: "9999", accounts: accounts,
            cardMappings: [:], defaultAccountId: "acct_hsbc")
        #expect(result == "acct_hsbc")
    }

    @Test func missingHintFallsBackToDefaultAccount() {
        let accounts = [account("acct_cash", "Cash"), account("acct_hsbc", "HSBC")]

        let result = PendingImportsView.seedAccountId(
            cardHint: nil, accounts: accounts,
            cardMappings: [:], defaultAccountId: "acct_hsbc")
        #expect(result == "acct_hsbc")
    }

    @Test func mappingToClosedAccountFallsThrough() {
        // The strict resolver must skip a mapping that points at a closed
        // account; the seed chain then lands on the first open account.
        let accounts = [account("acct_old", "Old Card", closed: true), account("acct_cash", "Cash")]

        let result = PendingImportsView.seedAccountId(
            cardHint: "1234", accounts: accounts,
            cardMappings: ["1234": "acct_old"], defaultAccountId: nil)
        #expect(result == "acct_cash")
    }

    @Test func closedDefaultFallsBackToFirstOpenAccount() {
        let accounts = [account("acct_old", "Old", closed: true), account("acct_cash", "Cash")]

        let result = PendingImportsView.seedAccountId(
            cardHint: nil, accounts: accounts,
            cardMappings: [:], defaultAccountId: "acct_old")
        #expect(result == "acct_cash")
    }

    @Test func noDefaultFallsBackToFirstOpenAccount() {
        let accounts = [account("acct_cash", "Cash"), account("acct_hsbc", "HSBC")]

        let result = PendingImportsView.seedAccountId(
            cardHint: nil, accounts: accounts,
            cardMappings: [:], defaultAccountId: nil)
        #expect(result == "acct_cash")
    }

    @Test func returnsNilOnlyWhenNoOpenAccounts() {
        let accounts = [account("acct_old", "Old", closed: true)]

        let result = PendingImportsView.seedAccountId(
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

        let result = PendingImportsView.seedAccountId(
            cardHint: "1234", accounts: accounts,
            cardMappings: ["1234": "acct_hsbc"], defaultAccountId: nil)
        #expect(result == "acct_hsbc")
    }

    @Test func approvalUsesTheSameFirstOpenFallbackAsTheEditor() {
        let accounts = [account("acct_old", "Closed", closed: true), account("acct_cash", "Cash")]

        let result = PendingImportApprover.resolveAccountId(
            cardHint: "unknown", accounts: accounts,
            cardMappings: [:], defaultAccountId: nil)

        #expect(result == "acct_cash")
    }

    @Test func legacyImportUsesReviewSeedForExplicitAdoption() {
        let legacy = PendingImport(amount: 25, payee: "Coffee")
        let accounts = [account("acct_cash", "Cash")]

        // A legacy record cannot be directly approved; opening the editor and
        // saving is the explicit adoption action into the active budget.
        #expect(legacy.originBudgetId == nil)
        #expect(PendingImportsView.seedAccountId(
            cardHint: legacy.cardHint,
            accounts: accounts,
            cardMappings: [:],
            defaultAccountId: nil
        ) == "acct_cash")
    }

    @Test func reviewSaveRequiresExplicitConfirmation() {
        let adoption = PendingImportReviewRequirement.adoptIntoActiveBudget
        let currency = PendingImportReviewRequirement.confirmActiveBudgetCurrency(source: "EUR", budget: "USD")
        #expect(!AddTransactionView.allowsReviewSave(requirement: adoption, confirmed: false))
        #expect(!AddTransactionView.allowsReviewSave(requirement: currency, confirmed: false))
        #expect(AddTransactionView.allowsReviewSave(requirement: adoption, confirmed: true))
        #expect(AddTransactionView.allowsReviewSave(requirement: nil, confirmed: false))
        #expect(currency.prompt.contains("no conversion"))
    }

    @Test func amountUsesBudgetCurrencyAndLocale() {
        #expect(PendingImportsView.amountString(
            1234.5, isIncome: false, currencyCode: "USD", sourceCurrencyCode: "EUR", narrowSymbol: false,
            locale: Locale(identifier: "de_DE")) == "-1.234,50 €")
        #expect(PendingImportsView.amountString(
            12.34, isIncome: false, currencyCode: "USD", sourceCurrencyCode: "EUR", narrowSymbol: false,
            locale: Locale(identifier: "de_DE")) == "-12,34 €")
        #expect(PendingImportsView.amountString(
            12.34, isIncome: true, currencyCode: "EUR", sourceCurrencyCode: "USD", narrowSymbol: true,
            locale: Locale(identifier: "en_US")) == "$12.34")
        #expect(PendingImportsView.amountString(
            12.34, isIncome: false, currencyCode: "USD", sourceCurrencyCode: nil, narrowSymbol: false,
            locale: Locale(identifier: "en_US")) == "-$12.34")
    }
}
