import Testing
@testable import Actuali

struct PendingImportsStillUnreviewedTests {
    private func makeTxn(_ id: String) -> Transaction {
        Transaction(
            id: id,
            accountId: "acct-1",
            date: 20_261_119,
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

    /// The Imported list is fetched once per data change, so a row swiped
    /// Reviewed has to leave by its mark, in the order the list was in.
    @Test func aRowLeavesTheListOnceItsMarkIsCleared() {
        let fetched = ["a", "b", "c"].map(makeTxn)
        let shown = PendingImportsView.stillUnreviewed(fetched, marks: ["c": "acct-1", "a": "acct-1"])
        #expect(shown.map(\.id) == ["a", "c"])
        #expect(PendingImportsView.stillUnreviewed(fetched, marks: [:]).isEmpty)
    }
}
