import Foundation
import Testing
@testable import Actuali

struct TransactionGroupingTests {

    private func makeTxn(_ id: String, date: Int) -> Transaction {
        Transaction(
            id: id,
            accountId: "acct-1",
            date: date,
            amount: -1000,
            payeeId: nil,
            payeeName: nil,
            categoryId: nil,
            categoryName: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )
    }

    @Test func emptyTransactionsReturnEmptyGroups() {
        let txs: [Transaction] = []
        let groups = txs.groupedByDate()
        #expect(groups.isEmpty)
    }

    @Test func singleTransactionFormsSingleGroup() {
        let tx = makeTxn("t-1", date: 20260814)
        let groups = [tx].groupedByDate()

        #expect(groups.count == 1)
        #expect(groups[0].date == 20260814)
        #expect(groups[0].transactions.map(\.id) == ["t-1"])
    }

    @Test func multipleTransactionsSameDateGroupTogether() {
        let t1 = makeTxn("t-1", date: 20260814)
        let t2 = makeTxn("t-2", date: 20260814)
        let t3 = makeTxn("t-3", date: 20260814)
        let groups = [t1, t2, t3].groupedByDate()

        #expect(groups.count == 1)
        #expect(groups[0].date == 20260814)
        #expect(groups[0].transactions.map(\.id) == ["t-1", "t-2", "t-3"])
    }

    @Test func multipleDatesPreserveOrdering() {
        let t1 = makeTxn("t-1", date: 20260814)
        let t2 = makeTxn("t-2", date: 20260814)
        let t3 = makeTxn("t-3", date: 20260813)
        let t4 = makeTxn("t-4", date: 20260813)
        let t5 = makeTxn("t-5", date: 20260812)

        let groups = [t1, t2, t3, t4, t5].groupedByDate()

        #expect(groups.count == 3)
        #expect(groups[0].date == 20260814)
        #expect(groups[0].transactions.map(\.id) == ["t-1", "t-2"])
        #expect(groups[1].date == 20260813)
        #expect(groups[1].transactions.map(\.id) == ["t-3", "t-4"])
        #expect(groups[2].date == 20260812)
        #expect(groups[2].transactions.map(\.id) == ["t-5"])
    }

    /// The logic under test is the YYYYMMDD split, not the localized spelling —
    /// asserting on "August" or "2026" would fail under a non-English locale or
    /// a non-Gregorian calendar.
    @Test func formattedDateDecodesTheDateInteger() {
        let expected = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 14))!

        #expect(Transaction.formattedDate(from: 20260814, style: .long)
            == expected.formatted(date: .long, time: .omitted))
        #expect(Transaction.formattedDate(from: 20260814, style: .abbreviated)
            == expected.formatted(date: .abbreviated, time: .omitted))
    }

    @Test func groupTitleSpellsOutTheDate() {
        let group = [makeTxn("t-1", date: 20260814)].groupedByDate()[0]
        #expect(group.title == Transaction.formattedDate(from: 20260814, style: .long))
    }
}
