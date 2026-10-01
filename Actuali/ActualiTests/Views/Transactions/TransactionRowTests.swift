import Foundation
import Testing
@testable import Actuali

struct TransactionRowTests {
    @Test func splitParentShowsSplitLabelInEveryTransactionList() {
        #expect(TransactionRow.splitSummaryLabel(
            isParent: true,
            locale: Locale(identifier: "en_US")
        ) == "Split")
    }

    @Test func nonSplitTransactionDoesNotUseSplitSummary() {
        #expect(TransactionRow.splitSummaryLabel(
            isParent: false,
            locale: Locale(identifier: "en_US")
        ) == nil)
    }

    @Test func splitParentKeepsPayeeAndUsesSplitAsSecondaryLabel() {
        let locale = Locale(identifier: "en_US")
        #expect(TransactionRow.payeeLabel(
            payeeName: "Grocery Store",
            isInOffBudgetAccount: false,
            locale: locale
        ) == "Grocery Store")
        #expect(TransactionRow.payeeLabel(
            payeeName: nil,
            isInOffBudgetAccount: false,
            locale: locale
        ) == "Unknown")
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
