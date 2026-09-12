import Testing
@testable import Actuali

struct TransactionRunningBalanceTests {
    @Test
    func runningBalanceWalksBackwardFromCurrentBalance() {
        let rows = [
            transaction(id: "1", amount: -3000),
            transaction(id: "2", amount: 5000),
            transaction(id: "3", amount: 8000)
        ]

        #expect(rows.withRunningBalances(startingAt: 10000).map(\.runningBalance) == [10000, 13000, 8000])
    }

    private func transaction(id: String, amount: Int) -> Transaction {
        Transaction(
            id: id,
            accountId: "account",
            date: 20260912,
            amount: amount,
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
}
