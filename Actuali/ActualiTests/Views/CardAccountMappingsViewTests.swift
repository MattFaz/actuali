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

    @Test func returnsEmptyWhenNoPendingImports() {
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: [],
            cardMappings: ["1234": "acct_chase"]
        )
        #expect(suggestions.isEmpty)
    }

    @Test func ignoresPendingImportsWithoutCardHint() {
        let imports = [
            makeImport(cardHint: nil, payee: "Coffee Shop"),
            makeImport(cardHint: "", payee: "Grocery Store"),
            makeImport(cardHint: "   ", payee: "Bookstore")
        ]
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: imports,
            cardMappings: [:]
        )
        #expect(suggestions.isEmpty)
    }

    @Test func ignoresCardHintsAlreadyMapped() {
        let imports = [
            makeImport(cardHint: "1234", payee: "Amazon"),
            makeImport(cardHint: "HSBC", payee: "Gas Station")
        ]
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: imports,
            cardMappings: [
                "1234": "acct_chase",
                "hsbc": "acct_hsbc"
            ]
        )
        #expect(suggestions.isEmpty)
    }

    @Test func ignoresHintsThatMatchExistingMappingCaseInsensitively() {
        let imports = [
            makeImport(cardHint: "hsbc", payee: "Dinner")
        ]
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: imports,
            cardMappings: ["HSBC": "acct_hsbc"]
        )
        #expect(suggestions.isEmpty)
    }

    @Test func returnsUnmappedCardHintsWithCountAndSamplePayee() {
        let imports = [
            makeImport(cardHint: "9876", payee: "Starbucks"),
            makeImport(cardHint: "1234", payee: "Amazon")
        ]
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: imports,
            cardMappings: ["1234": "acct_chase"]
        )
        #expect(suggestions.count == 1)
        #expect(suggestions[0].keyword == "9876")
        #expect(suggestions[0].count == 1)
        #expect(suggestions[0].samplePayee == "Starbucks")
    }

    @Test func groupsMultipleTransactionsForSameCard() {
        let imports = [
            makeImport(cardHint: "9876", payee: "Starbucks"),
            makeImport(cardHint: "9876", payee: "Target"),
            makeImport(cardHint: "5555", payee: "Uber")
        ]
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: imports,
            cardMappings: [:]
        )
        #expect(suggestions.count == 2)
        // 9876 should be first because it has count 2
        #expect(suggestions[0].keyword == "9876")
        #expect(suggestions[0].count == 2)
        #expect(suggestions[0].samplePayee == "Starbucks")

        #expect(suggestions[1].keyword == "5555")
        #expect(suggestions[1].count == 1)
        #expect(suggestions[1].samplePayee == "Uber")
    }

    @Test func sortsByCountDescendingThenAlphabetically() {
        let imports = [
            makeImport(cardHint: "ZZZZ", payee: "A"),
            makeImport(cardHint: "AAAA", payee: "B"),
            makeImport(cardHint: "MMMM", payee: "C"),
            makeImport(cardHint: "MMMM", payee: "D")
        ]
        let suggestions = CardAccountMappingsView.computeSuggestions(
            pendingImports: imports,
            cardMappings: [:]
        )
        #expect(suggestions.count == 3)
        #expect(suggestions[0].keyword == "MMMM") // count 2
        #expect(suggestions[1].keyword == "AAAA") // count 1, alphabetical
        #expect(suggestions[2].keyword == "ZZZZ") // count 1, alphabetical
    }
}
