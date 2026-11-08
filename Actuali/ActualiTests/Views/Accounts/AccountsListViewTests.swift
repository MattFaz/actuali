import Foundation
import SwiftUI
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

    // MARK: - Group drop targets

    private func groupHeaderRows(_ ids: [String]) -> [AccountListRow] {
        ids.enumerated().map { index, id in
            let group = AccountGroup(id: id, name: id, sortOrder: Double(index))
            return .header(AccountListBucket(id: id, group: group, accounts: []))
        }
    }

    @Test func groupDropTargetMovesAGroupBeforeTheNextVisibleGroup() {
        let rows = groupHeaderRows(["first", "middle", "last"])
        let target = AccountsListView.groupDropTarget(
            in: rows, at: 0, moving: "last", fullOrder: ["first", "middle", "last"]
        )
        #expect(target?.before == "first")
    }

    @Test func groupDropTargetAnchorsAfterTheLastVisibleGroupBeforeAnUnshownGroup() {
        let rows = groupHeaderRows(["first", "second"])
        let target = AccountsListView.groupDropTarget(
            in: rows, at: rows.count, moving: "first", fullOrder: ["first", "second", "empty"]
        )
        #expect(target?.before == "empty")
    }

    @Test func groupDropTargetIgnoresDroppingAHeaderBackIntoItsOwnPosition() {
        let rows = groupHeaderRows(["first", "second"])
        #expect(AccountsListView.groupDropTarget(
            in: rows, at: 1, moving: "first", fullOrder: ["first", "second"]
        ) == nil)
    }

    private func makeGroups(_ ids: [String]) -> [AccountGroup] {
        ids.enumerated().map { index, id in
            AccountGroup(id: id, name: id, sortOrder: Double(index))
        }
    }

    @Test func groupMoveTargetMovesAGroupBeforeTheNextGroup() {
        let groups = makeGroups(["first", "middle", "last"])
        let target = AccountsListView.groupMoveTarget(
            in: groups, from: IndexSet(integer: 2), to: 0
        )
        #expect(target?.before == "first")
    }

    @Test func groupMoveTargetAppendsWhenMovingToTheEnd() {
        let groups = makeGroups(["first", "middle", "last"])
        let target = AccountsListView.groupMoveTarget(
            in: groups, from: IndexSet(integer: 0), to: groups.count
        )
        #expect(target?.before == nil)
    }

    @Test func groupMoveTargetIgnoresAnUnchangedOrder() {
        let groups = makeGroups(["first", "middle", "last"])
        #expect(AccountsListView.groupMoveTarget(
            in: groups, from: IndexSet(integer: 1), to: 1
        ) == nil)
    }

    @Test func groupMoveTargetRejectsMultipleRowsAndInvalidSources() {
        let groups = makeGroups(["first", "middle", "last"])
        #expect(AccountsListView.groupMoveTarget(
            in: groups, from: IndexSet(integersIn: 0..<2), to: 2
        ) == nil)
        #expect(AccountsListView.groupMoveTarget(
            in: groups, from: IndexSet(integer: 3), to: 0
        ) == nil)
        #expect(AccountsListView.groupMoveTarget(
            in: groups, from: IndexSet(integer: 0), to: groups.count + 1
        ) == nil)
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

    @Test func collapseAllKeepsOtherBudgetsCollapsedGroups() {
        let ids = AccountsListView.collapsedGroupIDs(["other-budget"], groupIDs: ["b", "a"], collapsing: true)
        #expect(ids == "a,b,other-budget")
    }

    @Test func expandAllKeepsOtherBudgetsCollapsedGroups() {
        let ids = AccountsListView.collapsedGroupIDs(["a", "other-budget"], groupIDs: ["a", "b"], collapsing: false)
        #expect(ids == "other-budget")
    }

    @Test func collapseAllBeforeGroupsLoadKeepsRememberedGroups() {
        let ids = AccountsListView.collapsedGroupIDs(["a", "b"], groupIDs: [], collapsing: true)
        #expect(ids == "a,b")
    }

    // MARK: - Account payoff / term progress

    @Test func progressReturnsNilForUntrackedAccount() {
        let account = makeAccount("Checking")
        let progress = AccountRow.progress(
            for: account,
            loanConfig: nil,
            depositConfig: nil,
            creditCardDues: nil
        )
        #expect(progress == nil)
    }

    @Test func progressReturnsNilForClosedAccountEvenWithConfigs() {
        var account = makeAccount("Old Loan")
        account.closed = true
        let loan = LoanConfig(
            originalBalance: 1_000_000,
            annualRatePercent: 5.0,
            minimumPayment: 20000,
            escrowOrFees: nil
        )
        let progress = AccountRow.progress(
            for: account,
            loanConfig: loan,
            depositConfig: nil,
            creditCardDues: nil
        )
        #expect(progress == nil)
    }

    @Test func progressCalculatesLoanPayoffFraction() throws {
        var account = makeAccount("Car Loan")
        account.balance = -1_981_000
        let loan = LoanConfig(
            originalBalance: 2_200_000,
            annualRatePercent: 6.0,
            minimumPayment: 36500,
            escrowOrFees: nil
        )
        let progress = AccountRow.progress(
            for: account,
            loanConfig: loan,
            depositConfig: nil,
            creditCardDues: nil
        )
        // 2,200,000 original, 1,981,000 owed -> 219,000 paid (9.95%)
        let value = try #require(progress)
        #expect(abs(value - 0.0995) < 0.001)

        // Cleared loan -> 1.0 (100%)
        account.balance = 0
        #expect(AccountRow.progress(for: account, loanConfig: loan, depositConfig: nil, creditCardDues: nil) == 1.0)

        // Grew past original -> 0.0
        account.balance = -2_500_000
        #expect(AccountRow.progress(for: account, loanConfig: loan, depositConfig: nil, creditCardDues: nil) == 0.0)
    }

    @Test func progressCalculatesDepositTermElapsed() {
        let account = makeAccount("12-month CD")
        let deposit = DepositConfig(
            kind: .fixed,
            amount: 1_000_000,
            annualRatePercent: 4.5,
            compounding: .quarterly,
            openedOn: DayDate(year: 2026, month: 1, day: 1),
            termMonths: 12
        )
        // 6 months in on July 1
        let midDate = DayDate(year: 2026, month: 7, day: 1)
        let midProgress = AccountRow.progress(
            for: account,
            loanConfig: nil,
            depositConfig: deposit,
            creditCardDues: nil,
            today: midDate
        )
        #expect(midProgress == 0.5)

        // Matured on or after next year
        let matureDate = DayDate(year: 2027, month: 1, day: 1)
        let matureProgress = AccountRow.progress(
            for: account,
            loanConfig: nil,
            depositConfig: deposit,
            creditCardDues: nil,
            today: matureDate
        )
        #expect(matureProgress == 1.0)
    }

    @Test func progressCalculatesCreditCardStatementPayoff() {
        let account = makeAccount("Apple Card")
        let dueDate = DayDate(year: 2026, month: 3, day: 15)
        let today = DayDate(year: 2026, month: 3, day: 1)

        // 1. Partial payoff: $1000 statement balance, $300 remaining due -> 70% paid
        let partialDue = CreditCardCycle.StatementDue(
            statementBalance: 100_000,
            paymentsSince: 70000,
            remainingDue: 30000,
            dueDate: dueDate
        )
        let partialProgress = AccountRow.progress(
            for: account,
            loanConfig: nil,
            depositConfig: nil,
            creditCardDues: [partialDue],
            today: today
        )
        #expect(partialProgress == 0.7)

        // 2. Unpaid: $1000 statement balance, $1000 remaining due -> 0% paid
        let unpaidDue = CreditCardCycle.StatementDue(
            statementBalance: 100_000,
            paymentsSince: 0,
            remainingDue: 100_000,
            dueDate: dueDate
        )
        let unpaidProgress = AccountRow.progress(
            for: account,
            loanConfig: nil,
            depositConfig: nil,
            creditCardDues: [unpaidDue],
            today: today
        )
        #expect(unpaidProgress == 0.0)

        // 3. Paid: remaining due 0 -> 100% (1.0)
        let paidDue = CreditCardCycle.StatementDue(
            statementBalance: 100_000,
            paymentsSince: 100_000,
            remainingDue: 0,
            dueDate: dueDate
        )
        let paidProgress = AccountRow.progress(
            for: account,
            loanConfig: nil,
            depositConfig: nil,
            creditCardDues: [paidDue],
            today: today
        )
        #expect(paidProgress == 1.0)

        // 4. Zero statement balance -> nil (no statement debt)
        let zeroDue = CreditCardCycle.StatementDue(
            statementBalance: 0,
            paymentsSince: 0,
            remainingDue: 0,
            dueDate: dueDate
        )
        let zeroProgress = AccountRow.progress(
            for: account,
            loanConfig: nil,
            depositConfig: nil,
            creditCardDues: [zeroDue],
            today: today
        )
        #expect(zeroProgress == nil)
    }

    // MARK: - Avatar icons and color tints

    @Test func avatarIconMatchesAccountTypeAndConfigs() {
        #expect(AccountTypeAvatar.icon(for: .checking) == "banknote.fill")
        #expect(AccountTypeAvatar.icon(for: .savings) == "building.columns.fill")
        #expect(AccountTypeAvatar.icon(for: .credit) == "creditcard.fill")
        #expect(AccountTypeAvatar.icon(for: .investment) == "chart.line.uptrend.xyaxis")
        #expect(AccountTypeAvatar.icon(for: .mortgage) == "house.fill")
        #expect(AccountTypeAvatar.icon(for: .debt) == "exclamationmark.triangle.fill")
        #expect(AccountTypeAvatar.icon(for: .other) == "dollarsign.circle.fill")

        // Deposit config overrides type to lock.fill
        #expect(AccountTypeAvatar.icon(for: .savings, hasDeposit: true) == "lock.fill")

        // Loan config overrides type to house.fill
        #expect(AccountTypeAvatar.icon(for: .other, hasLoan: true) == "house.fill")

        // Credit card config overrides type to creditcard.fill
        #expect(AccountTypeAvatar.icon(for: .checking, hasCreditCard: true) == "creditcard.fill")
    }

    @Test func avatarColorsMatchAccountTypeAndClosedStatus() {
        // Checking uses blue
        #expect(AccountTypeAvatar.iconColor(for: .checking) == .blue)

        // Savings uses purple
        #expect(AccountTypeAvatar.iconColor(for: .savings) == .purple)

        // Credit uses orange (adaptive in light/dark mode)
        #expect(AccountTypeAvatar.iconColor(for: .credit) == .orange)
        #expect(AccountTypeAvatar.iconColor(for: .checking, hasCreditCard: true) == .orange)

        // Deposits and investments use green
        #expect(AccountTypeAvatar.iconColor(for: .investment) == .green)
        #expect(AccountTypeAvatar.iconColor(for: .savings, hasDeposit: true) == .green)

        // Loans use blue
        #expect(AccountTypeAvatar.iconColor(for: .other, hasLoan: true) == .blue)

        // Closed accounts use secondary
        #expect(AccountTypeAvatar.iconColor(for: .checking, closed: true) == .secondary)
        #expect(AccountTypeAvatar.iconColor(for: .credit, closed: true) == .secondary)
        #expect(AccountTypeAvatar.iconColor(for: .checking, hasCreditCard: true, closed: true) == .secondary)
    }

    @Test func progressBarColorFollowsInstrumentNotAccountType() {
        // A card can be tracked on any account type, so an unpaid bar is red
        // whenever the account carries neither a loan nor a deposit.
        #expect(AccountRow.progressBarColor(p: 0.4, hasLoan: false, hasDeposit: false) == .red)
        #expect(AccountRow.progressBarColor(p: 0.4, hasLoan: true, hasDeposit: false) == .blue)
        #expect(AccountRow.progressBarColor(p: 0.4, hasLoan: false, hasDeposit: true) == .green)
        #expect(AccountRow.progressBarColor(p: 1.0, hasLoan: false, hasDeposit: false) == .green)
    }
}
