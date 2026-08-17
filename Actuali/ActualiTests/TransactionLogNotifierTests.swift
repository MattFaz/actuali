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
        #expect(bodyEUR.contains("€12.50"))
        #expect(bodyEUR.contains("Starbucks"))

        let bodyGBP = TransactionLogNotifier.composeBody(
            message: "Error message",
            payee: "Tesco",
            amountCents: 500,
            currencyCode: "GBP",
            locale: enUS
        )
        #expect(bodyGBP.contains("£5.00"))
        #expect(bodyGBP.contains("Tesco"))
    }

    /// Expenses are negative cents; the failure body must carry that sign too
    /// (composeSuccessBody is covered separately below, GH #258).
    @Test func composeFailureBodyShowsExpenseAsNegative() {
        let body = TransactionLogNotifier.composeBody(
            message: "Error message",
            payee: "Starbucks",
            amountCents: -1250,
            currencyCode: "USD",
            locale: enUS
        )
        #expect(body == "-$12.50 at Starbucks. Error message")
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
        #expect(bodyNarrow.contains("$20.00"))
        #expect(bodyNarrow.contains("Supermarket"))
    }

    @Test func composeSuccessBodyUsesConfiguredCurrencyCode() {
        let bodyEUR = TransactionLogNotifier.composeSuccessBody(
            payee: "Starbucks",
            amountCents: 1250,
            currencyCode: "EUR",
            narrowSymbol: false,
            locale: enUS
        )
        #expect(bodyEUR.contains("€12.50"))
        #expect(bodyEUR.contains("Starbucks"))

        let bodyGBP = TransactionLogNotifier.composeSuccessBody(
            payee: "Tesco",
            amountCents: 500,
            currencyCode: "GBP",
            narrowSymbol: false,
            locale: enUS
        )
        #expect(bodyGBP.contains("£5.00"))
        #expect(bodyGBP.contains("Tesco"))
    }

    /// Expenses are negative cents (Actual's sign convention); the notification
    /// must show that sign so outflows read distinctly from income (GH #258).
    @Test func composeSuccessBodyShowsExpenseAsNegative() {
        let body = TransactionLogNotifier.composeSuccessBody(
            payee: "Starbucks",
            amountCents: -1250,
            currencyCode: "USD",
            narrowSymbol: false,
            locale: enUS
        )
        #expect(body == "-$12.50 at Starbucks")
    }

    @Test func composeSuccessBodyShowsIncomeAsPositive() {
        let body = TransactionLogNotifier.composeSuccessBody(
            payee: "Employer",
            amountCents: 1250,
            currencyCode: "USD",
            narrowSymbol: false,
            locale: enUS
        )
        #expect(body == "$12.50 at Employer")
    }

    /// A write that never reached the server must not read as a plain success —
    /// the transaction exists only on the phone until the next sync (issue #139).
    @Test func composeSuccessBodySaysWhenTheRowIsOnlyLocal() {
        let body = TransactionLogNotifier.composeSuccessBody(
            payee: "Starbucks",
            amountCents: 1250,
            currencyCode: "USD",
            narrowSymbol: false,
            synced: false,
            locale: enUS
        )
        #expect(body.hasPrefix("$12.50"))
        #expect(body.contains("Starbucks"))
        #expect(body.contains("Actuali"))
    }
}
