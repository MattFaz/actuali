import Foundation
import Testing
@testable import Actuali

@MainActor
struct TransactionLogNotifierTests {

    @Test func composeFailureBodyUsesConfiguredCurrencyCode() {
        let bodyEUR = TransactionLogNotifier.composeBody(
            message: "Error message",
            payee: "Starbucks",
            amountCents: 1250,
            currencyCode: "EUR"
        )
        #expect(bodyEUR.contains("€12.50 at Starbucks"))

        let bodyGBP = TransactionLogNotifier.composeBody(
            message: "Error message",
            payee: "Tesco",
            amountCents: 500,
            currencyCode: "GBP"
        )
        #expect(bodyGBP.contains("£5.00 at Tesco"))
    }

    @Test func composeFailureBodyHonorsNarrowSymbol() {
        let bodyNarrow = TransactionLogNotifier.composeBody(
            message: "Error message",
            payee: "Supermarket",
            amountCents: 2000,
            currencyCode: "NZD",
            narrowSymbol: true
        )
        #expect(bodyNarrow.contains("$20.00 at Supermarket"))
    }

    @Test func composeSuccessBodyUsesConfiguredCurrencyCode() {
        let bodyEUR = TransactionLogNotifier.composeSuccessBody(
            payee: "Starbucks",
            amountCents: 1250,
            currencyCode: "EUR",
            narrowSymbol: false
        )
        #expect(bodyEUR == "€12.50 at Starbucks")

        let bodyGBP = TransactionLogNotifier.composeSuccessBody(
            payee: "Tesco",
            amountCents: 500,
            currencyCode: "GBP",
            narrowSymbol: false
        )
        #expect(bodyGBP == "£5.00 at Tesco")
    }
}
