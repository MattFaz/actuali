import Foundation
import Testing
@testable import Actuali

struct AddTransactionSplitGateTests {
    @Test func plainTransactionOffersSplit() {
        #expect(AddTransactionView.canSplitIntoCategories(
            isTransfer: false, isEditingSplitParent: false, unsplitRequested: false
        ))
    }

    @Test func transferToggleHidesSplit() {
        // The live type toggle decides, not just a saved transfer: a new
        // transaction switched to Transfer can't be split (GH #556).
        #expect(!AddTransactionView.canSplitIntoCategories(
            isTransfer: true, isEditingSplitParent: false, unsplitRequested: false
        ))
    }

    @Test func splitParentOffersSplitOnlyAsUndo() {
        #expect(!AddTransactionView.canSplitIntoCategories(
            isTransfer: false, isEditingSplitParent: true, unsplitRequested: false
        ))
        #expect(AddTransactionView.canSplitIntoCategories(
            isTransfer: false, isEditingSplitParent: true, unsplitRequested: true
        ))
    }

    // MARK: - Sign key

    @Test(arguments: [
        (false, true, false, false, false, false, true), // Ordinary expense/income.
        (false, true, false, false, true, true, true), // New transfer with both accounts.
        (false, true, false, false, true, false, false), // No account to swap with.
        (true, false, false, false, false, false, false), // Split parent while children load.
        (true, true, false, false, false, false, true), // Loaded split parent can reverse all split lines.
        (false, true, true, false, true, true, false), // Existing transfer.
        (false, true, false, true, true, true, false), // Converting an existing row.
    ])
    func signToggleEligibility(
        isEditingSplitParent: Bool,
        splitLoaded: Bool,
        isEditingTransfer: Bool,
        isConvertingToTransfer: Bool,
        isTransfer: Bool,
        hasTransferPartner: Bool,
        expected: Bool
    ) {
        #expect(AddTransactionView.canToggleDirection(
            isEditingSplitParent: isEditingSplitParent,
            splitLoaded: splitLoaded,
            isEditingTransfer: isEditingTransfer,
            isConvertingToTransfer: isConvertingToTransfer,
            isTransfer: isTransfer,
            hasTransferPartner: hasTransferPartner
        ) == expected)
    }

    @Test func transferAccessibilityDescribesBothAccountsAndReversal() {
        let locale = Locale(identifier: "en")
        #expect(AddTransactionView.transferDirectionDescription(from: "Checking", to: "Savings", locale: locale)
            == "Transfer from Checking to Savings")
        #expect(AddTransactionView.transferDirectionDescription(from: "Savings", to: "Checking", locale: locale)
            == "Transfer from Savings to Checking")
        #expect(AddTransactionView.transferDirectionDescription(from: "Checking", to: nil, locale: locale) == "Transfer")
    }
}
