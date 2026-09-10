import Foundation
import Testing

@testable import Actuali

@Suite("Card account mappings suggestions")
struct CardAccountMappingsViewTests {
    private func makeImport(cardHint: String?, payee: String? = nil) -> PendingImport {
        PendingImport(
            id: UUID(),
            originBudgetId: "budget-1",
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
            accounts: accounts,
            cardMappings: [:]
        )
        #expect(suggestions.count == 3)
        #expect(suggestions[0].keyword == "MMMM") // count 2
        #expect(suggestions[1].keyword == "AAAA") // count 1, alphabetical
        #expect(suggestions[2].keyword == "ZZZZ") // count 1, alphabetical
    }
}
