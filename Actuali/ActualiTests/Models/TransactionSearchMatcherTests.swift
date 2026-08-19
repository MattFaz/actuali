import Testing
@testable import Actuali

struct TransactionSearchMatcherTests {
    private func makeTransaction(
        amount: Int,
        payeeName: String? = nil,
        categoryName: String? = nil,
        notes: String? = nil
    ) -> Transaction {
        Transaction(id: "t1", accountId: "a1", date: 20260701, amount: amount,
                    payeeId: nil, payeeName: payeeName,
                    categoryId: nil, categoryName: categoryName,
                    notes: notes, cleared: false, reconciled: false,
                    transferId: nil, isParent: false, parentId: nil,
                    tombstone: false, sortOrder: nil, importedPayee: nil)
    }

    // MARK: - Text matching (existing behavior)

    @Test func matchesPayeeCategoryAndNotesCaseInsensitively() {
        let tx = makeTransaction(amount: -1000, payeeName: "Coles", categoryName: "Groceries", notes: "weekly shop")
        #expect(TransactionSearchMatcher("coles").matches(tx))
        #expect(TransactionSearchMatcher("GROC").matches(tx))
        #expect(TransactionSearchMatcher("weekly").matches(tx))
        #expect(!TransactionSearchMatcher("fuel").matches(tx))
    }

    @Test func numericQueryStillMatchesTextFields() {
        let tx = makeTransaction(amount: -9999, notes: "invoice 12")
        #expect(TransactionSearchMatcher("12").matches(tx))
    }

    // MARK: - Amount matching

    @Test func decimalQueryMatchesExactAbsoluteAmount() {
        #expect(TransactionSearchMatcher("12.50").matches(makeTransaction(amount: -1250)))
        #expect(TransactionSearchMatcher("12.50").matches(makeTransaction(amount: 1250)))
        #expect(!TransactionSearchMatcher("12.50").matches(makeTransaction(amount: -1249)))
        #expect(!TransactionSearchMatcher("12.50").matches(makeTransaction(amount: -1251)))
    }

    @Test func wholeNumberQueryMatchesAnyCentsWithinThatDollar() {
        #expect(TransactionSearchMatcher("12").matches(makeTransaction(amount: -1200)))
        #expect(TransactionSearchMatcher("12").matches(makeTransaction(amount: -1234)))
        #expect(TransactionSearchMatcher("12").matches(makeTransaction(amount: 1299)))
        #expect(!TransactionSearchMatcher("12").matches(makeTransaction(amount: -1300)))
        #expect(!TransactionSearchMatcher("12").matches(makeTransaction(amount: -1199)))
    }

    @Test func currencySymbolAndSignAreIgnored() {
        #expect(TransactionSearchMatcher("$12.50").matches(makeTransaction(amount: -1250)))
        #expect(TransactionSearchMatcher("-12.50").matches(makeTransaction(amount: -1250)))
        #expect(TransactionSearchMatcher("-$12.50").matches(makeTransaction(amount: 1250)))
    }

    @Test func commaDecimalSeparatorIsAccepted() {
        #expect(TransactionSearchMatcher("12,50").matches(makeTransaction(amount: -1250)))
        #expect(TransactionSearchMatcher("12,5").matches(makeTransaction(amount: -1250)))
    }

    @Test func trailingSeparatorBehavesLikeWholeNumber() {
        #expect(TransactionSearchMatcher("19.").matches(makeTransaction(amount: -1905)))
        #expect(TransactionSearchMatcher("$19.").matches(makeTransaction(amount: -1905)))
        #expect(TransactionSearchMatcher("19,").matches(makeTransaction(amount: 1999)))
        #expect(!TransactionSearchMatcher("19.").matches(makeTransaction(amount: -2000)))
    }

    @Test func partialDecimalMatchesAsPrefixOnCents() {
        // "19.0" narrows to 19.00-19.09 while typing toward "19.05".
        #expect(TransactionSearchMatcher("19.0").matches(makeTransaction(amount: -1905)))
        #expect(!TransactionSearchMatcher("19.0").matches(makeTransaction(amount: -1910)))
        #expect(TransactionSearchMatcher("12.5").matches(makeTransaction(amount: -1250)))
        #expect(TransactionSearchMatcher("12.5").matches(makeTransaction(amount: -1259)))
        #expect(!TransactionSearchMatcher("12.5").matches(makeTransaction(amount: -1205)))
        #expect(!TransactionSearchMatcher("12.5").matches(makeTransaction(amount: -1260)))
    }

    @Test func fractionOnlyQueryMatchesCents() {
        #expect(TransactionSearchMatcher(".50").matches(makeTransaction(amount: -50)))
        #expect(TransactionSearchMatcher("0.50").matches(makeTransaction(amount: 50)))
        #expect(TransactionSearchMatcher(".5").matches(makeTransaction(amount: -55)))
    }

    @Test func groupingSeparatorQueryIsNotTreatedAsAmount() {
        // "1,234" is ambiguous (grouping vs. decimals); it falls back to text-only search.
        #expect(!TransactionSearchMatcher("1,234").matches(makeTransaction(amount: -123400)))
        #expect(!TransactionSearchMatcher("1,234").matches(makeTransaction(amount: -123)))
    }

    @Test func nonNumericQueryDoesNotMatchAmount() {
        #expect(!TransactionSearchMatcher("12a").matches(makeTransaction(amount: -1200)))
        #expect(!TransactionSearchMatcher("12.50.1").matches(makeTransaction(amount: -1250)))
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(TransactionSearchMatcher("").matches(makeTransaction(amount: -1250)))
        #expect(TransactionSearchMatcher("  ").matches(makeTransaction(amount: -1250)))
    }
}
