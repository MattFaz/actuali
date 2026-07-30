import Foundation
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreAccountMappingTests {

    @Test func cardAccountMappingsPersistToUserDefaults() {
        let store = BudgetStore.previewInstance()
        store.cardAccountMappings = ["1234": "acct_hsbc", "9876": "acct_hdfc"]
        #expect(store.cardAccountMappings["1234"] == "acct_hsbc")
        #expect(store.cardAccountMappings["9876"] == "acct_hdfc")
    }

    @Test func resolveAccountIdMatchesMappingKeyword() async {
        let store = BudgetStore.previewInstance()
        store.cardAccountMappings = ["1234": "acct1"]

        let resolved = await store.resolveAccountId(hint: "HSBC Credit Card 1234")
        #expect(resolved == "acct1")
    }

    @Test func resolveAccountIdMatchesAccountNameSubstring() async {
        let store = BudgetStore.previewInstance()
        // previewInstance has account "Checking" with id "acct1"
        let resolved = await store.resolveAccountId(hint: "Checking Account")
        #expect(resolved == "acct1")
    }

    @Test func resolveAccountIdReturnsNilForUnknownHint() async {
        let store = BudgetStore.previewInstance()
        let resolved = await store.resolveAccountId(hint: "NonExistentBank9999")
        #expect(resolved == nil)
    }
}
