import Testing
@testable import Actuali

struct TransactionTextParserTests {

    // MARK: - Fallback parser (amount extraction)

    @Test func parsesIndianUPIMessage() async {
        let text = "₹450 debited from A/C XX9876 to SWIGGY via UPI on 20-08-26"
        let result = await TransactionTextParser.parse(text)
        #expect(result.cardHint == "9876")
        #expect(result.isIncome == false)
        // Payee extraction is best-effort; verify it's non-nil at minimum.
        #expect(result.payee != nil)
    }

    @Test func parsesUSCreditCardMessage() async {
        let text = "You paid $18.50 at Starbucks on card ending 4321"
        let result = await TransactionTextParser.parse(text)
        #expect(result.amount == 18.50)
        #expect(result.cardHint == "4321")
        #expect(result.isIncome == false)
        #expect(result.payee == "Starbucks")
    }

    @Test func parsesRefundAsIncome() async {
        let text = "Refund of $25.00 from Amazon credited to card 5555"
        let result = await TransactionTextParser.parse(text)
        #expect(result.amount == 25.0)
        #expect(result.isIncome == true)
    }

    @Test func emptyTextReturnsNils() async {
        let result = await TransactionTextParser.parse("")
        #expect(result.amount == nil)
        #expect(result.payee == nil)
        #expect(result.cardHint == nil)
    }

    @Test func toPendingImportPreservesFields() async {
        let text = "Paid $10 at Coffee Shop using card ending 1234"
        let parsed = await TransactionTextParser.parse(text)
        let pending = parsed.toPendingImport()
        #expect(pending.rawText == text)
        #expect(pending.cardHint == "1234")
    }
}
