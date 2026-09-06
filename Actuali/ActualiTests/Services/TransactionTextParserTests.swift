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

    @Test func toPendingImportPreservesOriginBudgetId() {
        let pending = TransactionTextParser.parseWithFallback("Paid $10 at Coffee")
            .toPendingImport(originBudgetId: "budget-a")

        #expect(pending.originBudgetId == "budget-a")
    }
}
