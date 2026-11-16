import Foundation
import Testing
@testable import Actuali

struct AddTransactionSplitGateTests {
    @Test func schedulingEligibilityRequiresANewFutureNonSplitTransaction() throws {
        let calendar = Calendar.current
        let today = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 13, hour: 12
        )))
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: today))

        func eligible(
            isEditing: Bool = false,
            hasSaveOverride: Bool = false,
            reviewRequirements: [PendingImportReviewRequirement] = [],
            hasSplits: Bool = false,
            date: Date
        ) -> Bool {
            AddTransactionView.canSchedule(
                isEditing: isEditing,
                hasSaveOverride: hasSaveOverride,
                reviewRequirements: reviewRequirements,
                hasSplits: hasSplits,
                date: date,
                today: today
            )
        }

        #expect(eligible(date: tomorrow))
        #expect(!eligible(isEditing: true, date: tomorrow))
        #expect(!eligible(hasSaveOverride: true, date: tomorrow))
        #expect(!eligible(reviewRequirements: [.adoptIntoActiveBudget], date: tomorrow))
        #expect(!eligible(hasSplits: true, date: tomorrow))
        #expect(!eligible(date: today))
    }

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
        (false, true, false, false, false, true), // Ordinary expense/income.
        (false, true, false, true, true, true), // New or existing transfer with both accounts (GH #844).
        (false, true, false, true, false, false), // No account to swap with, e.g. an unresolved partner.
        (true, false, false, false, false, false), // Split parent while children load.
        (true, true, false, false, false, true), // Loaded split parent can reverse all split lines.
        (false, true, true, true, true, false), // Converting an existing row.
    ])
    func signToggleEligibility(
        isEditingSplitParent: Bool,
        splitLoaded: Bool,
        isConvertingToTransfer: Bool,
        isTransfer: Bool,
        hasTransferPartner: Bool,
        expected: Bool
    ) {
        #expect(AddTransactionView.canToggleDirection(
            isEditingSplitParent: isEditingSplitParent,
            splitLoaded: splitLoaded,
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
