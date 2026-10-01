import Foundation
import Testing
@testable import Actuali

struct TransactionRowTests {
    private let locale = Locale(identifier: "en_US")

    private func payee(_ name: String?, isParent: Bool = false, offBudget: Bool = false) -> String {
        TransactionRow.payeeLabel(
            payeeName: name,
            isParent: isParent,
            isInOffBudgetAccount: offBudget,
            locale: locale
        )
    }

    private func category(
        _ name: String?,
        isParent: Bool = false,
        splitBreakdown: String? = nil,
        offBudget: Bool = false,
        isTransfer: Bool = false,
        needsCategory: Bool = false
    ) -> String {
        TransactionRow.categoryLabel(
            categoryName: name,
            isParent: isParent,
            splitBreakdown: splitBreakdown,
            isInOffBudgetAccount: offBudget,
            isTransfer: isTransfer,
            needsCategory: needsCategory,
            locale: locale
        )
    }

    @Test func payeeLabelShowsResolvedPayee() {
        #expect(payee("Grocery Store", isParent: true) == "Grocery Store")
        #expect(payee("Grocery Store") == "Grocery Store")
    }

    @Test func payeeLabelFallbacks() {
        // Mixed child payees resolve nil; the parent still reads as a split.
        #expect(payee(nil, isParent: true) == "Split")
        #expect(payee(nil, isParent: true, offBudget: true) == "Split")
        #expect(payee(nil, offBudget: true) == "No payee")
        #expect(payee(nil) == "Unknown")
    }

    @Test func splitParentShowsSplitThenBreakdown() {
        #expect(category(nil, isParent: true, splitBreakdown: "Food $6.00, Fun +$4.00")
            == "Split・Food $6.00, Fun +$4.00")
        #expect(category(nil, isParent: true) == "Split")
    }

    @Test func categoryLabelPreservesCategoryTransferAndUncategorized() {
        #expect(category("Groceries", needsCategory: true) == "Groceries")
        #expect(category(nil, isTransfer: true) == "Transfer")
        #expect(category(nil, isTransfer: true, needsCategory: true) == "Uncategorized")
        #expect(category(nil) == "Uncategorized")
    }

    @Test func offBudgetTakesPrecedenceOverSplit() {
        #expect(category("Food", isParent: true, splitBreakdown: "Food $6.00", offBudget: true)
            == "Off budget")
    }
}
