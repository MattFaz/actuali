import Foundation
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreCreditLimitTests {

    /// Points the store at a throwaway budget and clears every card key it
    /// touches, so a run can't leak config into the real app's defaults (same
    /// convention as BudgetStoreAccountMappingTests).
    private func withStore(_ body: @MainActor (BudgetStore) async -> Void) async {
        let savedDefault = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer {
            UserDefaults.standard.removeObject(forKey: "creditCardStatementDays_test-budget")
            UserDefaults.standard.removeObject(forKey: "creditCardDueOffsets_test-budget")
            UserDefaults.standard.removeObject(forKey: "creditCardLimits_test-budget")
            UserDefaults.standard.set(savedDefault, forKey: "currentBudgetId")
        }
        let store = BudgetStore.previewInstance()
        store.currentBudgetId = "test-budget"
        await body(store)
    }

    private func account(id: String, name: String, type: AccountType = .credit,
                         closed: Bool = false, balance: Int = 0) -> Account {
        Account(id: id, name: name, type: type, offBudget: false, closed: closed,
                sortOrder: 0, balance: balance)
    }

    /// A card's balance is negative while money is owed, so headroom is the limit
    /// plus the balance — the sign is the whole point of this test.
    @Test func availableCreditIsTheLimitLessWhatIsOwed() async {
        await withStore { store in
            store.accounts = [account(id: "acct_card", name: "Card", balance: -614_900)]
            store.setCreditCard(accountId: "acct_card", statementDay: 25)
            store.setCreditLimit(accountId: "acct_card", cents: 1_000_000)

            #expect(store.creditCardLimits["acct_card"] == 1_000_000)
            #expect(store.availableCredit(for: "acct_card") == 385_100)

            // Over the limit reads negative rather than clamping — being $100
            // over is a fact worth showing.
            store.accounts = [account(id: "acct_card", name: "Card", balance: -1_010_000)]
            #expect(store.availableCredit(for: "acct_card") == -10_000)

            // Overpaid card: headroom exceeds the limit.
            store.accounts = [account(id: "acct_card", name: "Card", balance: 5_000)]
            #expect(store.availableCredit(for: "acct_card") == 1_005_000)
        }
    }

    @Test func availableCreditIsNilWithoutALimitOrAnActiveCard() async {
        await withStore { store in
            store.accounts = [
                account(id: "acct_nolimit", name: "No Limit", balance: -1_000),
                account(id: "acct_closed", name: "Closed", closed: true, balance: -1_000),
                account(id: "acct_untracked", name: "Checking", type: .checking, balance: -1_000),
            ]
            store.setCreditCard(accountId: "acct_nolimit", statementDay: 15)
            store.setCreditCard(accountId: "acct_closed", statementDay: 15)
            store.setCreditLimit(accountId: "acct_closed", cents: 500_000)
            // A limit with no cycle behind it: the account was never marked as a
            // card, so there is nothing to show a figure on.
            store.setCreditLimit(accountId: "acct_untracked", cents: 500_000)

            #expect(store.availableCredit(for: "acct_nolimit") == nil)
            #expect(store.availableCredit(for: "acct_closed") == nil)
            #expect(store.availableCredit(for: "acct_untracked") == nil)
            #expect(store.availableCredit(for: "acct_missing") == nil)
        }
    }

    @Test func limitClearsWithTheCardAndOnAnEmptyEntry() async {
        await withStore { store in
            store.setCreditCard(accountId: "acct_card", statementDay: 25)
            store.setCreditLimit(accountId: "acct_card", cents: 1_000_000)

            // Untracking the card must not leave the limit behind to be picked up
            // by a later card on the same account.
            store.setCreditCard(accountId: "acct_card", statementDay: nil)
            #expect(store.creditCardLimits["acct_card"] == nil)

            // An emptied field in the sheet clears a previously stored limit...
            store.setCreditCard(accountId: "acct_card", statementDay: 25)
            store.setCreditLimit(accountId: "acct_card", cents: 1_000_000)
            store.setCreditLimit(accountId: "acct_card", cents: nil)
            #expect(store.creditCardLimits["acct_card"] == nil)

            // ...while an ordinary cycle edit leaves it alone.
            store.setCreditLimit(accountId: "acct_card", cents: 1_000_000)
            store.setCreditCard(accountId: "acct_card", statementDay: 3, dueOffsetDays: 25)
            #expect(store.creditCardLimits["acct_card"] == 1_000_000)
        }
    }

    @Test func limitIsScopedToTheBudgetThatSetIt() async {
        await withStore { store in
            store.setCreditCard(accountId: "acct_card", statementDay: 15)
            store.setCreditLimit(accountId: "acct_card", cents: 1_000_000)

            store.currentBudgetId = "other-budget"
            #expect(store.creditCardLimits.isEmpty)
        }
    }
}
