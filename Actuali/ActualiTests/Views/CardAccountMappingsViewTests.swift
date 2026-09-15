import Foundation
import Testing

@testable import Actuali

@Suite("Card account mappings suggestions")
struct CardAccountMappingsViewTests {
    private func makeImport(
        cardHint: String?,
        payee: String? = nil,
        originBudgetId: String? = "budget-1"
    ) -> PendingImport {
        PendingImport(
            id: UUID(),
            originBudgetId: originBudgetId,
            amount: 25.0,
            sourceCurrencyCode: "USD",
            payee: payee,
            cardHint: cardHint,
            date: Date(),
            isIncome: false,
            rawText: "sample notification text",
            createdAt: Date()
        )
    }

    private func account(_ id: String, name: String, closed: Bool = false) -> Account {
        Account(id: id, name: name, type: .checking, offBudget: false, closed: closed, sortOrder: 0, balance: 0)
    }

    @Test func returnsEmptyWhenNoPendingImports() {
        let accounts = [account("acct_chase", name: "Chase")]
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: [],
            activeBudgetId: "budget-1",
            accounts: accounts,
            cardMappings: ["1234": "acct_chase"]
        )
        #expect(suggestions.isEmpty)
    }

    @Test func ignoresPendingImportsWithoutCardHint() {
        let accounts = [account("acct_chase", name: "Chase")]
        let imports = [
            makeImport(cardHint: nil, payee: "Coffee Shop"),
            makeImport(cardHint: "", payee: "Grocery Store"),
            makeImport(cardHint: "   ", payee: "Bookstore")
        ]
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: imports,
            activeBudgetId: "budget-1",
            accounts: accounts,
            cardMappings: [:]
        )
        #expect(suggestions.isEmpty)
    }

    @Test func ignoresCardHintsAlreadyMapped() {
        let accounts = [
            account("acct_chase", name: "Chase"),
            account("acct_hsbc", name: "HSBC")
        ]
        let imports = [
            makeImport(cardHint: "1234", payee: "Amazon"),
            makeImport(cardHint: "HSBC", payee: "Gas Station")
        ]
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: imports,
            activeBudgetId: "budget-1",
            accounts: accounts,
            cardMappings: [
                "1234": "acct_chase",
                "hsbc": "acct_hsbc"
            ]
        )
        #expect(suggestions.isEmpty)
    }

    @Test func ignoresHintsThatMatchExistingMappingCaseInsensitively() {
        let accounts = [account("acct_hsbc", name: "HSBC Account")]
        let imports = [
            makeImport(cardHint: "hsbc", payee: "Dinner")
        ]
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: imports,
            activeBudgetId: "budget-1",
            accounts: accounts,
            cardMappings: ["HSBC": "acct_hsbc"]
        )
        #expect(suggestions.isEmpty)
    }

    @Test func ignoresHintsThatMatchAccountNameDirectly() {
        let accounts = [account("acct_checking", name: "HSBC Checking")]
        let imports = [
            makeImport(cardHint: "HSBC Checking", payee: "Coffee")
        ]
        // Even with no card mappings, hint matches open account name so it routes already
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: imports,
            activeBudgetId: "budget-1",
            accounts: accounts,
            cardMappings: [:]
        )
        #expect(suggestions.isEmpty)
    }

    @Test func suggestsCardMappedToClosedAccount() {
        let accounts = [
            account("acct_closed", name: "Old Chase", closed: true),
            account("acct_active", name: "Active Checking", closed: false)
        ]
        let imports = [
            makeImport(cardHint: "1234", payee: "Groceries")
        ]
        // 1234 maps to a closed account, so routing fails and falls through -> should be suggested to repair
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: imports,
            activeBudgetId: "budget-1",
            accounts: accounts,
            cardMappings: ["1234": "acct_closed"]
        )
        #expect(suggestions.count == 1)
        #expect(suggestions[0].keyword == "1234")
    }

    @Test func returnsUnmappedCardHintsWithCountAndSamplePayee() {
        let accounts = [account("acct_chase", name: "Chase")]
        let imports = [
            makeImport(cardHint: "9876", payee: "Starbucks"),
            makeImport(cardHint: "1234", payee: "Amazon")
        ]
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: imports,
            activeBudgetId: "budget-1",
            accounts: accounts,
            cardMappings: ["1234": "acct_chase"]
        )
        #expect(suggestions.count == 1)
        #expect(suggestions[0].keyword == "9876")
        #expect(suggestions[0].count == 1)
        #expect(suggestions[0].samplePayee == "Starbucks")
    }

    @Test func groupsMultipleTransactionsForSameCard() {
        let accounts = [account("acct_main", name: "Main")]
        let imports = [
            makeImport(cardHint: "9876", payee: "Starbucks"),
            makeImport(cardHint: "9876", payee: "Target"),
            makeImport(cardHint: "5555", payee: "Uber")
        ]
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: imports,
            activeBudgetId: "budget-1",
            accounts: accounts,
            cardMappings: [:]
        )
        #expect(suggestions.count == 2)
        #expect(suggestions[0].keyword == "9876")
        #expect(suggestions[0].count == 2)
        #expect(suggestions[0].samplePayee == "Starbucks")

        #expect(suggestions[1].keyword == "5555")
        #expect(suggestions[1].count == 1)
        #expect(suggestions[1].samplePayee == "Uber")
    }

    @Test func sortsByCountDescendingThenAlphabetically() {
        let accounts = [account("acct_main", name: "Main")]
        let imports = [
            makeImport(cardHint: "ZZZZ", payee: "A"),
            makeImport(cardHint: "AAAA", payee: "B"),
            makeImport(cardHint: "MMMM", payee: "C"),
            makeImport(cardHint: "MMMM", payee: "D")
        ]
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: imports,
            activeBudgetId: "budget-1",
            accounts: accounts,
            cardMappings: [:]
        )
        #expect(suggestions.count == 3)
        #expect(suggestions[0].keyword == "MMMM") // count 2
        #expect(suggestions[1].keyword == "AAAA") // count 1, alphabetical
        #expect(suggestions[2].keyword == "ZZZZ") // count 1, alphabetical
    }

    @Test func editingWithoutRenameRemovesNothing() {
        #expect(CardAccountMappingsView.keywordsRemovedBySave(originalKeywords: [], cleanedKeywords: ["1234"]).isEmpty)
        #expect(CardAccountMappingsView.keywordsRemovedBySave(originalKeywords: ["1234"], cleanedKeywords: ["1234"]).isEmpty)
    }

    @Test func renamingAKeywordRemovesTheOriginalKey() {
        #expect(CardAccountMappingsView.keywordsRemovedBySave(originalKeywords: ["1234"], cleanedKeywords: ["4321"]) == ["1234"])
    }

    @Test func caseOnlyRenameRemovesTheOriginalKey() {
        // Resolution lowercases hints, but dictionary keys are exact, so a
        // case-only rename must still drop the old key or the list shows two
        // rows for one mapping.
        #expect(CardAccountMappingsView.keywordsRemovedBySave(originalKeywords: ["HSBC"], cleanedKeywords: ["hsbc"]) == ["HSBC"])
    }

    @Test func multiKeywordSaveRemovesOnlyDeletedKeywords() {
        let original = ["1234", "5678", "CSR"]
        let cleaned = ["1234", "CSR", "9999"]
        let removed = CardAccountMappingsView.keywordsRemovedBySave(originalKeywords: original, cleanedKeywords: cleaned)
        #expect(removed == ["5678"])
    }

    @Test func multiKeywordSaveWithNoDeletionsRemovesNothing() {
        let original = ["1234", "CSR"]
        let cleaned = ["1234", "CSR", "9999"]
        let removed = CardAccountMappingsView.keywordsRemovedBySave(originalKeywords: original, cleanedKeywords: cleaned)
        #expect(removed.isEmpty)
    }

    @Test func groupByAccountGroupsAndSortsAccountsAndKeywords() {
        let accounts = [
            account("acct_chase", name: "Chase Sapphire"),
            account("acct_citi", name: "Citi Double Cash")
        ]
        let mappings = [
            "CSR": "acct_chase",
            "1234": "acct_chase",
            "5678": "acct_chase",
            "CitiDC": "acct_citi",
            "9012": "acct_citi"
        ]
        let grouped = CardAccountMappingsView.groupByAccount(cardMappings: mappings, accounts: accounts)

        #expect(grouped.count == 2)
        #expect(grouped[0].accountId == "acct_chase")
        #expect(grouped[0].accountName == "Chase Sapphire")
        #expect(grouped[0].keywords == ["1234", "5678", "CSR"])

        #expect(grouped[1].accountId == "acct_citi")
        #expect(grouped[1].accountName == "Citi Double Cash")
        #expect(grouped[1].keywords == ["9012", "CitiDC"])
    }

    @Test func groupByAccountHandlesUnknownAndDuplicateAccountNames() {
        let accounts = [
            account("acct_1", name: "Savings"),
            account("acct_2", name: "Savings")
        ]
        let mappings = [
            "1111": "acct_1",
            "2222": "acct_2",
            "3333": "acct_missing"
        ]
        let grouped = CardAccountMappingsView.groupByAccount(cardMappings: mappings, accounts: accounts)

        #expect(grouped.count == 3)
        let missing = grouped.first { $0.accountId == "acct_missing" }
        #expect(missing?.accountName == "Unknown Account")
        #expect(missing?.keywords == ["3333"])
    }

    @Test func filtersOtherBudgetsButKeepsLegacyImports() {
        let imports = [
            makeImport(cardHint: "1111"),
            makeImport(cardHint: "2222", originBudgetId: "budget-2"),
            makeImport(cardHint: "3333", originBudgetId: nil)
        ]
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: imports,
            activeBudgetId: "budget-1",
            accounts: [account("acct_main", name: "Main")],
            cardMappings: [:]
        )
        #expect(suggestions.map(\.keyword) == ["1111", "3333"])
    }
}
