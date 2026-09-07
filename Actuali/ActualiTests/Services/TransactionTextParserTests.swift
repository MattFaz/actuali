import Testing
@testable import Actuali

struct TransactionTextParserTests {

    // MARK: - Deterministic Fallback Parser Tests

    @Test func parsesIndianUPIMessage() {
        let text = "A/c XX9876 debited by Rs.500.00 on 20-08-26 to SWIGGY via UPI"
        let result = TransactionTextParser.parseWithFallback(text)
        #expect(result.amount == 500.00)
        #expect(result.sourceCurrencyCode == nil)
        #expect(result.cardHint == "9876")
        #expect(result.isIncome == false)
        #expect(result.payee == "SWIGGY")
    }

    @Test func parsesUSCreditCardMessage() {
        let text = "Card ending 4321: $18.50 at Starbucks"
        let result = TransactionTextParser.parseWithFallback(text)
        #expect(result.amount == 18.50)
        #expect(result.sourceCurrencyCode == nil)
        #expect(result.cardHint == "4321")
        #expect(result.isIncome == false)
        #expect(result.payee == "Starbucks")
    }

    @Test func parsesRefundAsIncomeAndDoesNotCaptureCardAsMerchant() {
        let text = "Refund of $25.00 from Amazon credited to card 5555"
        let result = TransactionTextParser.parseWithFallback(text)
        #expect(result.amount == 25.0)
        #expect(result.isIncome == true)
        #expect(result.cardHint == "5555")
        // "card 5555" must NOT be extracted as payee
        #expect(result.payee != "card 5555")
    }

    @Test func emptyTextReturnsNils() {
        let result = TransactionTextParser.parseWithFallback("")
        #expect(result.amount == nil)
        #expect(result.payee == nil)
        #expect(result.cardHint == nil)
    }

    @Test func toPendingImportPreservesFields() {
        let text = "Paid $10 at Coffee Shop using card ending 1234"
        let parsed = TransactionTextParser.parseWithFallback(text)
        let pending = parsed.toPendingImport()
        #expect(pending.rawText == text)
        #expect(pending.cardHint == "1234")
        #expect(pending.amount == 10.0)
        #expect(pending.sourceCurrencyCode == nil)
    }

    @Test func preservesConfidentSourceCurrency() {
        let parsed = TransactionTextParser.parseWithFallback("Paid EUR 100.00 at Bakery")
        #expect(parsed.sourceCurrencyCode == "EUR")
        #expect(parsed.toPendingImport().sourceCurrencyCode == "EUR")
    }

    @Test func preservesExplicitIndianCurrencyCode() {
        #expect(TransactionTextParser.parseWithFallback("Paid INR 100 at Store").sourceCurrencyCode == "INR")
    }

    @Test func preservesAdditionalExplicitIsoCurrencyCodes() {
        #expect(TransactionTextParser.parseWithFallback("Paid CAD 100 at Store").sourceCurrencyCode == "CAD")
        #expect(TransactionTextParser.parseWithFallback("Paid AUD 100 at Store").sourceCurrencyCode == "AUD")
        #expect(TransactionTextParser.parseWithFallback("Paid JPY 100 at Store").sourceCurrencyCode == "JPY")
        #expect(TransactionTextParser.parseWithFallback("Paid CHF 100 at Store").sourceCurrencyCode == "CHF")
    }

    @Test func extractsAmountAdjacentToAnyExplicitIsoCurrencyCode() {
        let leading = TransactionTextParser.parseWithFallback(
            "Card ending 4321 was charged (CAD): 25.50 at Store"
        )
        let trailing = TransactionTextParser.parseWithFallback(
            "Card ending 4321 was charged 19.75 CHF at Store"
        )

        #expect(leading.amount == 25.50)
        #expect(leading.sourceCurrencyCode == "CAD")
        #expect(trailing.amount == 19.75)
        #expect(trailing.sourceCurrencyCode == "CHF")
    }

    @Test func requiresUppercaseExplicitIsoCurrencyCode() {
        #expect(TransactionTextParser.parseWithFallback("Paid cad 100 at Store").sourceCurrencyCode == nil)
    }

    @Test func doesNotTreatTitleCaseProseAsLeadingCurrencyCode() {
        let parsed = TransactionTextParser.parseWithFallback("Try 100 at Store")
        #expect(parsed.sourceCurrencyCode == nil)
        #expect(parsed.amount == 100)
        #expect(parsed.payee == "Store")
        #expect(parsed.rawText == "Try 100 at Store")
    }

    @Test func acceptsUppercaseTurkishLiraInLeadingPosition() {
        #expect(TransactionTextParser.parseWithFallback("TRY 100 at Store").sourceCurrencyCode == "TRY")
    }

    @Test func acceptsTurkishLiraInTrailingPosition() {
        #expect(TransactionTextParser.parseWithFallback("100 TRY at Store").sourceCurrencyCode == "TRY")
    }

    @Test func rejectsLowercaseCurrencyCodeInTrailingPosition() {
        #expect(TransactionTextParser.parseWithFallback("100 try at Store").sourceCurrencyCode == nil)
    }

    @Test func doesNotTreatTitleCaseProseAsTrailingCurrencyCode() {
        #expect(TransactionTextParser.parseWithFallback("100 Try at Store").sourceCurrencyCode == nil)
    }

    @Test func acceptsPunctuationAroundExplicitCurrencyCode() {
        #expect(TransactionTextParser.parseWithFallback("Paid (CAD): 100 at Store").sourceCurrencyCode == "CAD")
        #expect(TransactionTextParser.parseWithFallback("Paid 100, CAD. at Store").sourceCurrencyCode == "CAD")
    }

    @Test func rejectsUnknownCurrencyCode() {
        #expect(TransactionTextParser.parseWithFallback("Paid XYZ 100 at Store").sourceCurrencyCode == nil)
    }

    @Test func doesNotTreatThreeLetterProseAsCurrency() {
        #expect(TransactionTextParser.parseWithFallback("Paid the 100 at Store").sourceCurrencyCode == nil)
    }

    @Test func toPendingImportPreservesOriginBudgetId() {
        let pending = TransactionTextParser.parseWithFallback("Paid $10 at Coffee")
            .toPendingImport(originBudgetId: "budget-a")

        #expect(pending.originBudgetId == "budget-a")
    }
}

extension TransactionTextParserTests {
    @Test func lowercaseProseIsNotCurrency() {
        let parsed = TransactionTextParser.parseWithFallback("Debited 500 all accounts on 12 Jan")
        #expect(parsed.sourceCurrencyCode == nil)
    }
}
