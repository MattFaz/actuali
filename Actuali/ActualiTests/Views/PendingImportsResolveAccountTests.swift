import Testing
@testable import Actuali

struct PendingImportsResolveAccountTests {

    private func account(_ id: String, _ name: String, closed: Bool = false) -> Account {
        Account(id: id, name: name, type: .checking, offBudget: false, closed: closed,
                sortOrder: 0, balance: 0)
    }

    // MARK: - Card mapping resolution

    @Test func resolvesViaCardMapping() {
        let accounts = [account("acct_hsbc", "HSBC"), account("acct_cash", "Cash")]
        let mappings = ["1234": "acct_hsbc"]

        let result = BudgetStore.resolveAccountId(
            hint: "1234", accounts: accounts, cardMappings: mappings)
        #expect(result == "acct_hsbc")
    }

    @Test func prefersLongestMappingKey() {
        let accounts = [account("acct1", "A"), account("acct2", "B")]
        let mappings = ["12": "acct1", "1234": "acct2"]

        let result = BudgetStore.resolveAccountId(
            hint: "1234", accounts: accounts, cardMappings: mappings)
        #expect(result == "acct2")
    }

    @Test func skipsMappingForClosedAccount() {
        let accounts = [account("acct1", "HSBC", closed: true), account("acct2", "Cash")]
        let mappings = ["1234": "acct1"]

        let result = BudgetStore.resolveAccountId(
            hint: "1234", accounts: accounts, cardMappings: mappings)
        // Mapping points to closed account — should not match
        #expect(result == nil)
    }

    // MARK: - Account name fallback

    @Test func matchesExactAccountName() {
        let accounts = [account("acct1", "Checking")]
        let result = BudgetStore.resolveAccountId(
            hint: "Checking", accounts: accounts, cardMappings: [:])
        #expect(result == "acct1")
    }

    @Test func matchesAccountNameByWholeWords() {
        let accounts = [account("acct1", "Checking")]
        let result = BudgetStore.resolveAccountId(
            hint: "Checking Account", accounts: accounts, cardMappings: [:])
        #expect(result == "acct1")
    }

    @Test func doesNotMatchSubstringInsideLargerWord() {
        let accounts = [account("acct1", "Cash")]
        // "cashback" contains "cash" as substring, not as a word
        let result = BudgetStore.resolveAccountId(
            hint: "HSBC cashback card", accounts: accounts, cardMappings: [:])
        #expect(result == nil)
    }

    @Test func returnsNilWhenNoOpenAccounts() {
        let accounts = [account("acct1", "Cash", closed: true)]
        let result = BudgetStore.resolveAccountId(
            hint: "Cash", accounts: accounts, cardMappings: [:])
        #expect(result == nil)
    }

    @Test func returnsNilForEmptyHint() {
        let accounts = [account("acct1", "Cash")]
        let result = BudgetStore.resolveAccountId(
            hint: "  ", accounts: accounts, cardMappings: [:])
        #expect(result == nil)
    }

    // MARK: - Regression: the exact scenario from the bug report

    @Test func resolvesMappedCardHintInsteadOfFirstAccount() {
        // "Spent 300 via 1234 hsbc at AWS m on 15th Aug 2026"
        // Parser extracts cardHint "1234", mapping routes to HSBC.
        // Before the fix: fell through to Cash (first account).
        let accounts = [account("acct_cash", "Cash"), account("acct_hsbc", "HSBC")]
        let mappings = ["1234": "acct_hsbc"]

        let result = BudgetStore.resolveAccountId(
            hint: "1234", accounts: accounts, cardMappings: mappings)
        #expect(result == "acct_hsbc")
    }
}
