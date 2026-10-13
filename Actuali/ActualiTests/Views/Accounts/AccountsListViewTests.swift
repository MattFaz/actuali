import Foundation
import Testing
@testable import Actuali

struct AccountsListViewTests {
    private func makeAccount(_ name: String) -> Account {
        Account(
            id: UUID().uuidString,
            name: name,
            type: .checking,
            offBudget: false,
            closed: false,
            sortOrder: 0,
            balance: 0
        )
    }

    private func names(_ query: String, in accounts: [Account]) -> [String] {
        AccountsListView.filterAccounts(accounts, matching: query).map(\.name)
    }

    @Test func filterAccounts() {
        let accounts = [
            "Chequing",
            "Savings",
            "Visa Credit",
            "Tangerine Chequing",
        ].map(makeAccount)

        #expect(names("", in: accounts).count == 4)
        #expect(names("   ", in: accounts).count == 4)
        #expect(names("\n\t ", in: accounts).count == 4)
        #expect(names("chequing", in: accounts) == ["Chequing", "Tangerine Chequing"])
        #expect(names("CREDIT", in: accounts) == ["Visa Credit"])
        #expect(names("  savings ", in: accounts) == ["Savings"])
        #expect(names("\nSAVINGS\t", in: accounts) == ["Savings"])
        #expect(names("savings", in: []).isEmpty)
        #expect(names("mortgage", in: accounts).isEmpty)
        #expect(names("i", in: accounts) == [
            "Chequing",
            "Savings",
            "Visa Credit",
            "Tangerine Chequing",
        ])
    }

    @Test func singleAccountGroupRowRoundsBothEndsWhenNextRowHasDifferentBackground() {
        #expect(AccountGroupRowLayout.position(roundsTop: true, roundsBottom: true) == .single)
    }

    @Test func firstAndMiddleRowsKeepOnlyTheirOuterTopCorner() {
        #expect(AccountGroupRowLayout.position(roundsTop: true, roundsBottom: false) == .first)
        #expect(AccountGroupRowLayout.position(roundsTop: false, roundsBottom: false) == .middle)
    }

    @Test func lastAccountRowRoundsWhenNextGroupUsesClearBackground() {
        let nextGroupIsExpanded = true
        #expect(AccountGroupRowLayout.position(roundsTop: false, roundsBottom: nextGroupIsExpanded) == .last)
    }

    @Test func lastAccountRowDoesNotRoundWhenNextGroupSharesItsBackground() {
        let nextGroupIsExpanded = false
        #expect(AccountGroupRowLayout.position(roundsTop: false, roundsBottom: nextGroupIsExpanded) == .middle)
    }

    @Test func collapsedGroupHeaderRoundsAtSectionStartAndBeforeExpandedGroup() {
        let headerIsFirst = true
        let nextGroupIsExpanded = true
        #expect(AccountGroupRowLayout.position(roundsTop: headerIsFirst, roundsBottom: nextGroupIsExpanded) == .single)
    }

    @Test func adjacentCollapsedGroupHeadersShareOneBackgroundWithoutRoundedJoin() {
        let headerIsFirst = false
        let nextGroupIsExpanded = false
        #expect(AccountGroupRowLayout.position(roundsTop: headerIsFirst, roundsBottom: nextGroupIsExpanded) == .middle)
    }

    // MARK: - Drop slots

    /// Ungrouped A, B; then group Cash holding C.
    private func dropRows() -> (rows: [AccountListRow], ungrouped: AccountListBucket, cash: AccountListBucket) {
        let ungrouped = AccountListBucket(id: "ungrouped", group: nil, accounts: [makeAccount("A"), makeAccount("B")])
        let cash = AccountListBucket(
            id: "cash", group: AccountGroup(id: "cash", name: "Cash", sortOrder: 0), accounts: [makeAccount("C")]
        )
        let rows: [AccountListRow] = [
            .account(ungrouped.accounts[0], offset: 0, bucket: ungrouped),
            .account(ungrouped.accounts[1], offset: 1, bucket: ungrouped),
            .header(cash),
            .account(cash.accounts[0], offset: 0, bucket: cash),
        ]
        return (rows, ungrouped, cash)
    }

    @Test(arguments: [
        (0, "ungrouped", 0), // top of the list
        (2, "ungrouped", 2), // below B, above the Cash header: end of ungrouped
        (3, "cash", 0), // just below the header: top of Cash
        (4, "cash", 1), // below C: end of Cash
    ])
    func dropSlotLandsAfterTheRowAbove(destination: Int, bucketId: String, index: Int) {
        let slot = AccountsListView.dropSlot(in: dropRows().rows, at: destination)
        #expect(slot?.bucket.id == bucketId)
        #expect(slot?.index == index)
    }

    @Test func dropSlotBelowACollapsedHeaderIsTheTopOfThatGroup() {
        let (_, ungrouped, cash) = dropRows()
        // Collapsed: the header shows, its accounts don't.
        let rows: [AccountListRow] = [
            .account(ungrouped.accounts[0], offset: 0, bucket: ungrouped),
            .header(cash),
        ]
        let slot = AccountsListView.dropSlot(in: rows, at: 2)
        #expect(slot?.bucket.id == "cash")
        #expect(slot?.index == 0)
    }

    @Test func dropSlotAboveALeadingHeaderIsIgnored() {
        let (_, _, cash) = dropRows()
        #expect(AccountsListView.dropSlot(in: [.header(cash)], at: 0) == nil)
    }
}
