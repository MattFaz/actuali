import Testing
@testable import Actuali

/// Covers `PendingImportsView.seedAccountId` — the edit form's account seed
/// chain: strict hint resolution, then default account, then first open
/// account. The strict matcher itself is covered by
/// `BudgetStoreAccountMappingTests`.
struct PendingImportsResolveAccountTests {

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
}
