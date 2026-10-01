import Foundation
import Testing
@testable import Actuali

struct TransactionRowTests {
    @Test func splitParentKeepsPayeeAndUsesSplitAsSecondaryLabel() {
        let locale = Locale(identifier: "en_US")
        #expect(TransactionRow.payeeLabel(
            payeeName: "Grocery Store",
            isParent: true,
            isInOffBudgetAccount: false,
            locale: locale
        ) == "Grocery Store")
        #expect(TransactionRow.payeeLabel(
            payeeName: nil,
            isParent: true,
            isInOffBudgetAccount: false,
            locale: locale
        ) == "No payee")
        #expect(TransactionRow.secondaryLabel(
            categoryName: "Food",
            isParent: true,
            isInOffBudgetAccount: false,
            isTransfer: false,
            needsCategory: false,
            locale: locale
        ) == "Split")
    }

    @Test func secondaryLabelPreservesNormalCategoryAndTransferLabels() {
        let locale = Locale(identifier: "en_US")
        #expect(TransactionRow.secondaryLabel(
            categoryName: "Groceries",
            isParent: false,
            isInOffBudgetAccount: false,
            isTransfer: false,
            needsCategory: true,
            locale: locale
        ) == "Groceries")
        #expect(TransactionRow.secondaryLabel(
            categoryName: nil,
            isParent: false,
            isInOffBudgetAccount: false,
            isTransfer: true,
            needsCategory: false,
            locale: locale
        ) == "Transfer")
    }

    @Test func secondaryLabelKeepsOffBudgetPrecedence() {
        #expect(TransactionRow.secondaryLabel(
            categoryName: "Food",
            isParent: true,
            isInOffBudgetAccount: true,
            isTransfer: false,
            needsCategory: false,
            locale: Locale(identifier: "en_US")
        ) == "Off budget")
    }
}
