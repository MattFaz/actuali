import Foundation
import SwiftUI
import Testing
import UIKit
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

    @Test @MainActor func accountNamesWrapAtDefaultAndAccessibilitySizes() throws {
        for (size, name) in [
            (DynamicTypeSize.large, "Chase Checking Everyday Spending"),
            (.accessibility5, "Chase Checking"),
        ] {
            let short = try renderedRow(accountName: "A", size: size)
            let long = try renderedRow(accountName: name, size: size)
            #expect(long.height > short.height)
        }
    }

    @Test @MainActor func notesHaveTheirOwnLineAndWrapInNarrowRows() throws {
        let empty = try renderedRow(width: 320)
        let short = try renderedRow(notes: "Memo", width: 320)
        let long = try renderedRow(
            notes: "Paid for groceries and household supplies at the neighborhood market.",
            width: 320
        )
        #expect(short.height > empty.height)
        #expect(long.height > short.height)
    }

    @Test @MainActor func tagChipsOnlyRenderWhenTheyFit() throws {
        for width: CGFloat in [220, 600] {
            let red = try renderedRow(notes: "#reimbursable", width: width, tagColor: "#ff0000")
            let blue = try renderedRow(notes: "#reimbursable", width: width, tagColor: "#0000ff")
            let redPixels = try #require(red.dataProvider?.data as Data?)
            let bluePixels = try #require(blue.dataProvider?.data as Data?)
            // Changing tag metadata changes only the chips, not the raw note.
            #expect((redPixels != bluePixels) == (width == 600))
        }
    }

    @MainActor
    private func renderedRow(
        accountName: String = "A",
        notes: String? = nil,
        width: CGFloat = 390,
        size: DynamicTypeSize = .large,
        tagColor: String = "#ff0000"
    ) throws -> CGImage {
        let store = BudgetStore.previewInstance()
        store.accounts = [Account(
            id: "account", name: accountName, type: .checking,
            offBudget: false, closed: false, sortOrder: 0, balance: 0
        )]
        store.tags = [Tag(tag: "reimbursable", color: tagColor)]
        let transaction = Transaction(
            id: "transaction", accountId: "account", date: 20_261_004, amount: -100,
            payeeId: nil, payeeName: "Cafe", categoryId: "category", categoryName: "Food",
            notes: notes, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: nil, importedPayee: nil
        )
        let renderer = ImageRenderer(content: TransactionRow(transaction: transaction, showDate: false)
            .environmentObject(store)
            .environment(\.locale, locale)
            .environment(\.colorScheme, .light)
            .dynamicTypeSize(size)
            .frame(width: width))
        renderer.scale = 1
        return try #require(renderer.uiImage?.cgImage)
    }
}
