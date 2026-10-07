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
        #expect(category(nil, isParent: true, splitBreakdown: "Food $6.00\nFun +$4.00")
            == "Split\nFood $6.00\nFun +$4.00")
        #expect(category(nil, isParent: true) == "Split")
    }

    @Test @MainActor func splitPortionsEachGetTheirOwnLine() throws {
        let food = Actuali.Transaction.SplitPortion(categoryName: "Food", amount: -60)
        let fun = Actuali.Transaction.SplitPortion(categoryName: "Fun", amount: -40)
        let one = try renderedRow(splitPortions: [food])
        let two = try renderedRow(splitPortions: [food, fun])
        #expect(two.height > one.height)
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

    @Test @MainActor func tagChipsRenderOnceInlineAtNarrowAndWideWidths() throws {
        for width: CGFloat in [220, 600] {
            let red = try renderedRow(notes: "#reimbursable", width: width, tagColor: "#ff0000")
            let blue = try renderedRow(notes: "#reimbursable", width: width, tagColor: "#0000ff")
            let redPixels = try #require(red.dataProvider?.data as Data?)
            let bluePixels = try #require(blue.dataProvider?.data as Data?)
            #expect(redPixels != bluePixels)
            let changedRows = Set((0..<red.height).filter { row in
                let start = row * red.bytesPerRow
                let end = start + red.bytesPerRow
                return redPixels[start..<end] != bluePixels[start..<end]
            })
            // One band of colored pixels means the tag is not also beside the category.
            #expect(changedRows.filter { !changedRows.contains($0 - 1) }.count == 1)
        }
    }

    @Test @MainActor func longUnbrokenNotesWrapInNarrowRows() throws {
        let short = try renderedRow(notes: "Memo", width: 320)
        for note in [
            "https://example.com/receipts/" + String(repeating: "abcdef", count: 20),
            String(repeating: "食料品の領収書", count: 12),
        ] {
            let long = try renderedRow(notes: note, width: 320)
            #expect(long.height > short.height)
        }
    }

    @Test @MainActor func notesPreserveExplicitAndBlankLines() throws {
        let oneLine = try renderedRow(notes: "First Second", width: 320)
        let twoLines = try renderedRow(notes: "First\nSecond", width: 320)
        let blankLine = try renderedRow(notes: "First\n\nSecond", width: 320)
        #expect(twoLines.height > oneLine.height)
        #expect(blankLine.height > twoLines.height)
        let spacedBlankLine = try renderedRow(notes: "First\n \nSecond", width: 320)
        #expect(spacedBlankLine.height == blankLine.height)
        for newline in ["\r\n", "\u{2028}"] {
            let alternate = try renderedRow(notes: "First" + newline + "Second", width: 320)
            #expect(alternate.height == twoLines.height)
        }
        let taggedLines = try renderedRow(notes: "#reimbursable\nSecond", width: 320)
        let taggedSingleLine = try renderedRow(notes: "#reimbursable Second", width: 320)
        #expect(taggedLines.height > taggedSingleLine.height)
    }

    @Test @MainActor func overlongTagKeepsTheAmountVisible() throws {
        let short = try renderedRow(notes: "#item", width: 220)
        let long = try renderedRow(notes: "#" + String(repeating: "item", count: 100), width: 220)
        #expect(long.height == short.height)
        let amountBounds = CGRect(x: 172, y: 0, width: 48, height: short.height)
        let shortAmount = try #require(short.cropping(to: amountBounds))
        let longAmount = try #require(long.cropping(to: amountBounds))
        #expect(UIImage(cgImage: longAmount).pngData() == UIImage(cgImage: shortAmount).pngData())
    }

    @MainActor
    private func renderedRow(
        accountName: String = "A",
        notes: String? = nil,
        splitPortions: [Actuali.Transaction.SplitPortion]? = nil,
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
        var transaction = Transaction(
            id: "transaction", accountId: "account", date: 20_261_004, amount: -100,
            payeeId: nil, payeeName: "Cafe", categoryId: "category", categoryName: "Food",
            notes: notes, cleared: false, reconciled: false, transferId: nil,
            isParent: splitPortions != nil, parentId: nil, tombstone: false, sortOrder: nil, importedPayee: nil
        )
        transaction.splitPortions = splitPortions
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
