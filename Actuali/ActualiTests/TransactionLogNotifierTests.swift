import Foundation
import Testing
@testable import Actuali

@MainActor
struct TransactionLogNotifierTests {

    // Locale is pinned: the composers format via the runner's locale by
    // default, and symbol placement differs by locale (de_DE renders
    // "12,50 €").
    private let enUS = Locale(identifier: "en_US")

    @Test func composeFailureBodyUsesConfiguredCurrencyCode() {
        let bodyEUR = TransactionLogNotifier.composeBody(
            message: "Error message",
            payee: "Starbucks",
            amountCents: 1250,
            currencyCode: "EUR",
            locale: enUS
        )
        #expect(bodyEUR.contains("€12.50 at Starbucks"))

        let bodyGBP = TransactionLogNotifier.composeBody(
            message: "Error message",
            payee: "Tesco",
            amountCents: 500,
            currencyCode: "GBP",
            locale: enUS
        )
        #expect(bodyGBP.contains("£5.00 at Tesco"))
    }

    @Test func composeFailureBodyHonorsNarrowSymbol() {
        let bodyNarrow = TransactionLogNotifier.composeBody(
            message: "Error message",
            payee: "Supermarket",
            amountCents: 2000,
            currencyCode: "NZD",
            narrowSymbol: true,
            locale: enUS
        )
        #expect(bodyNarrow.contains("$20.00 at Supermarket"))
    }

    @Test func composeSuccessBodyUsesConfiguredCurrencyCode() {
        let bodyEUR = TransactionLogNotifier.composeSuccessBody(
            payee: "Starbucks",
            amountCents: 1250,
            currencyCode: "EUR",
            narrowSymbol: false,
            locale: enUS
        )
        #expect(bodyEUR == "€12.50 at Starbucks")

        let bodyGBP = TransactionLogNotifier.composeSuccessBody(
            payee: "Tesco",
            amountCents: 500,
            currencyCode: "GBP",
            narrowSymbol: false,
            locale: enUS
        )
        #expect(bodyGBP == "£5.00 at Tesco")
    }
}
