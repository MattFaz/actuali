import Foundation
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreAccountMappingTests {

    /// Runs `body` with a store whose budget is `test-budget`, then restores
    /// the UserDefaults state the store's `currentBudgetId.didSet` and the
    /// mappings setter persist — so tests don't leak into the host app's
    /// defaults (same convention as BudgetStoreEnsureBudgetReadyTests).
    private func withMappingStore(_ body: @MainActor (BudgetStore) async -> Void) async {
        let savedDefault = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer {
            UserDefaults.standard.removeObject(forKey: "cardAccountMappings_test-budget")
            UserDefaults.standard.set(savedDefault, forKey: "currentBudgetId")
        }
        let store = BudgetStore.previewInstance()
        store.currentBudgetId = "test-budget"
        await body(store)
    }

    private func account(_ id: String, _ name: String, closed: Bool = false) -> Account {
        Account(id: id, name: name, type: .checking, offBudget: false, closed: closed,
                sortOrder: 0, balance: 0)
    }

    @Test func cardAccountMappingsPersistToUserDefaults() async {
        await withMappingStore { store in
            store.cardAccountMappings = ["1234": "acct_hsbc", "9876": "acct_hdfc"]
            #expect(store.cardAccountMappings["1234"] == "acct_hsbc")
            #expect(store.cardAccountMappings["9876"] == "acct_hdfc")
        }
    }

    @Test func resolveAccountIdMatchesMappingKeyword() async {
        await withMappingStore { store in
            store.accounts = [account("acct1", "Checking")]
            store.cardAccountMappings = ["1234": "acct1"]

            let resolved = await store.resolveAccountId(hint: "HSBC Credit Card 1234")
            #expect(resolved == "acct1")
        }
    }

    @Test func resolveAccountIdPrefersLongestMappingKey() async {
        await withMappingStore { store in
            store.accounts = [account("acct1", "Checking"), account("acct2", "Savings")]
            store.cardAccountMappings = ["12": "acct1", "1234": "acct2"]

            let resolved = await store.resolveAccountId(hint: "Card 1234")
            #expect(resolved == "acct2")
        }
    }

    @Test func resolveAccountIdDoesNotMatchPartialHintAgainstMappingKey() async {
        await withMappingStore { store in
            store.accounts = [account("acct1", "Checking")]
            store.cardAccountMappings = ["1234": "acct1"]

            // A hint that's a fragment of a keyword must not match — the
            // reverse direction would let "4" route money to "1234"'s account.
            let resolved = await store.resolveAccountId(hint: "4")
            #expect(resolved == nil)
        }
    }

    @Test func resolveAccountIdMatchesAccountNameByWholeWords() async {
        await withMappingStore { store in
            store.accounts = [account("acct1", "Checking")]
            let resolved = await store.resolveAccountId(hint: "Checking Account")
            #expect(resolved == "acct1")
        }
    }

    @Test func resolveAccountIdDoesNotMatchNameInsideLargerWord() async {
        await withMappingStore { store in
            store.accounts = [account("acct1", "Cash")]
            // "cashback" contains "cash" as a substring, not as a word.
            let resolved = await store.resolveAccountId(hint: "HSBC cashback card")
            #expect(resolved == nil)
        }
    }

    @Test func resolveAccountIdReturnsNilWhenNameMatchIsAmbiguous() async {
        await withMappingStore { store in
            store.accounts = [account("acct1", "Card"), account("acct2", "HSBC")]
            // Both names appear as words in the hint — refuse to guess so the
            // intent falls back to the default account or a visible error.
            let resolved = await store.resolveAccountId(hint: "HSBC credit card")
            #expect(resolved == nil)
        }
    }

    @Test func resolveAccountIdReturnsNilForUnknownHint() async {
        await withMappingStore { store in
            store.accounts = [account("acct1", "Checking")]
            let resolved = await store.resolveAccountId(hint: "NonExistentBank9999")
            #expect(resolved == nil)
        }
    }

    // The static entry point is what the pending-import edit form calls;
    // these cover its edges without a store.

    @Test func resolveAccountIdSkipsMappingToClosedAccount() {
        let resolved = BudgetStore.resolveAccountId(
            hint: "1234",
            accounts: [account("acct1", "HSBC", closed: true), account("acct2", "Cash")],
            cardMappings: ["1234": "acct1"])
        #expect(resolved == nil)
    }

    @Test func resolveAccountIdReturnsNilForBlankHint() {
        let resolved = BudgetStore.resolveAccountId(
            hint: "  ",
            accounts: [account("acct1", "Cash")],
            cardMappings: [:])
        #expect(resolved == nil)
    }
}
