import Testing
@testable import Actuali

struct AccountDetailTransactionDisplayTests {
    @Test func displayKeepsOrderAndBalancesAcrossDateGroups() {
        let rows = [
            transaction("expense", date: 20_261_002, amount: -3000),
            transaction("income", date: 20_261_002, amount: 5000),
            transaction("older", date: 20_261_001, amount: 8000),
        ]
        let display = AccountDetailView.transactionDisplay(rows, startingBalance: 10000)

        #expect(display.transactions.map(\.id) == ["expense", "income", "older"])
        #expect(display.transactions.map(\.runningBalance) == [10000, 13000, 8000])
        #expect(display.groups.map(\.date) == [20_261_002, 20_261_001])
        #expect(display.groups.map { $0.transactions.map(\.id) } == [["expense", "income"], ["older"]])
        #expect(display.groups.flatMap(\.transactions) == display.transactions)
        #expect(rows.allSatisfy { $0.runningBalance == nil })
    }

    @Test func filteredOrHiddenBalancesKeepTheOriginalRows() {
        let rows = [transaction("result", date: 20_261_002, amount: -3000)]
        let display = AccountDetailView.transactionDisplay(rows, startingBalance: nil)

        #expect(display.transactions == rows)
        #expect(display.groups.flatMap(\.transactions) == rows)
    }

    @MainActor @Test func pagingContinuesBalancesAndMergesDates() async {
        let rows = [
            transaction("first", date: 20_261_002, amount: -3000),
            transaction("next", date: 20_261_002, amount: 5000),
            transaction("last", date: 20_261_001, amount: -1000),
        ]
        let pager = TransactionPager(pageSize: 1) { offset, limit, _ in
            Array(rows.dropFirst(offset).prefix(limit))
        }
        await pager.loadFirstPage()
        let first = AccountDetailView.transactionDisplay(pager.transactions, startingBalance: -2000)
        #expect(first.transactions.map(\.runningBalance) == [-2000])

        await pager.loadNextPage()
        await pager.loadNextPage()
        let display = AccountDetailView.transactionDisplay(pager.transactions, startingBalance: -2000)
        #expect(display.transactions.map(\.runningBalance) == [-2000, 1000, -4000])
        #expect(display.groups.map { $0.transactions.map(\.id) } == [["first", "next"], ["last"]])
        #expect(display.groups.flatMap(\.transactions) == display.transactions)
    }

    @Test func emptyPageHasNoRowsOrGroups() {
        let display = AccountDetailView.transactionDisplay([], startingBalance: 10000)
        #expect(display.transactions.isEmpty)
        #expect(display.groups.isEmpty)
    }

    private func transaction(_ id: String, date: Int, amount: Int) -> Transaction {
        Transaction(
            id: id, accountId: "account", date: date, amount: amount,
            payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: nil,
            importedPayee: nil
        )
    }
}
