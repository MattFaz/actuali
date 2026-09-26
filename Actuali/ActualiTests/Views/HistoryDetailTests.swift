import Foundation
import Testing
@testable import Actuali

struct HistoryDetailTests {
    private func transaction(
        id: String,
        amount: Int = -1000,
        payeeId: String? = "payee",
        payeeName: String? = "Groceries",
        categoryId: String? = "category",
        categoryName: String? = "Food",
        notes: String? = nil,
        date: Int = 20_260_906,
        isParent: Bool = false,
        parentId: String? = nil
    ) -> Transaction {
        Transaction(
            id: id,
            accountId: "account",
            date: date,
            amount: amount,
            payeeId: payeeId,
            payeeName: payeeName,
            categoryId: categoryId,
            categoryName: categoryName,
            notes: notes,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: isParent,
            parentId: parentId,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )
    }

    private func action(before: [Transaction], after: [Transaction]) -> HistoryAction {
        HistoryAction(
            id: UUID().uuidString,
            createdAt: Date(),
            budgetID: "budget",
            kind: .edited,
            before: before,
            after: after,
            status: .applied
        )
    }

    @Test func splitChildAmountEditReportsTheChildAmount() {
        let parentBefore = transaction(id: "parent", categoryId: nil, categoryName: nil, isParent: true)
        let parentAfter = parentBefore
        let childBefore = transaction(id: "child", amount: -600, parentId: "parent")
        let childAfter = transaction(id: "child", amount: -700, parentId: "parent")

        let detail = HistoryView.editedDetail(
            for: action(before: [parentBefore, childBefore], after: [parentAfter, childAfter]),
            primary: parentAfter,
            formatCurrency: { "\($0)" }
        )

        #expect(detail == String(format: String(localized: "Amount: %@ → %@"), "-600", "-700"))
    }

    @Test func payeeEditUsesPayeeIdChange() {
        let before = transaction(id: "txn", payeeId: "payee-old", payeeName: "Old Payee")
        let after = transaction(id: "txn", payeeId: "payee-new", payeeName: "New Payee")

        let detail = HistoryView.editedDetail(
            for: action(before: [before], after: [after]),
            primary: after,
            formatCurrency: { "\($0)" }
        )

        #expect(detail == String(format: String(localized: "Payee: %@ → %@"), "Old Payee", "New Payee"))
    }

    @Test func categoryEditUsesCategoryIdChange() {
        let before = transaction(id: "txn", categoryId: "category-old", categoryName: "Old Category")
        let after = transaction(id: "txn", categoryId: "category-new", categoryName: "New Category")

        let detail = HistoryView.editedDetail(
            for: action(before: [before], after: [after]),
            primary: after,
            formatCurrency: { "\($0)" }
        )

        #expect(detail == String(format: String(localized: "Category: %@ → %@"), "Old Category", "New Category"))
    }

    @Test func dateEditUsesTheLocalizedDateFormatKey() {
        let before = transaction(id: "txn", date: 20_260_906)
        let after = transaction(id: "txn", date: 20_260_909)

        let detail = HistoryView.editedDetail(
            for: action(before: [before], after: [after]),
            primary: after,
            formatCurrency: { "\($0)" }
        )

        let expected = String(
            format: String(localized: "Date: %@ → %@"),
            Transaction.formattedDate(from: before.date),
            Transaction.formattedDate(from: after.date)
        )
        #expect(detail == expected)
    }

    @Test func splitChildNoteEditReportsTheChildNote() {
        let parent = transaction(id: "parent", categoryId: nil, categoryName: nil, isParent: true)
        let childBefore = transaction(id: "child", notes: "old note", parentId: "parent")
        let childAfter = transaction(id: "child", notes: "new note", parentId: "parent")

        let detail = HistoryView.editedDetail(
            for: action(before: [parent, childBefore], after: [parent, childAfter]),
            primary: parent,
            formatCurrency: { "\($0)" }
        )

        #expect(detail == String(localized: "Note changed"))
    }

    @Test func changeToAnotherTransactionIsNotAttributedToThePrimary() {
        let primary = transaction(id: "primary")
        let otherBefore = transaction(id: "other", amount: -600)
        let otherAfter = transaction(id: "other", amount: -700)

        let detail = HistoryView.editedDetail(
            for: action(before: [primary, otherBefore], after: [primary, otherAfter]),
            primary: primary,
            formatCurrency: { "\($0)" }
        )

        #expect(detail == nil)
    }
}
