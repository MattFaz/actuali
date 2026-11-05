import Testing
@testable import Actuali

struct TransactionsListViewTests {
    private func makeAccount(
        _ id: String,
        offBudget: Bool,
        closed: Bool = false,
        sortOrder: Int
    ) -> Account {
        Account(
            id: id,
            name: id,
            type: .checking,
            offBudget: offBudget,
            closed: closed,
            sortOrder: sortOrder,
            balance: 0
        )
    }

    private func makeUpcomingEntry(_ id: String, accountId: String?) -> UpcomingScheduleEntry {
        let date = DayDate(year: 2026, month: 10, day: 29)
        let schedule = ScheduleSummary(
            id: id,
            name: id,
            ruleId: nil,
            nextDate: date,
            nextDateRowId: nil,
            baseNextDateTs: nil,
            accountId: accountId,
            payeeId: nil,
            amount: .fixed(100),
            amountOp: .isExactly,
            dateOp: nil,
            dateCondition: nil,
            postsTransaction: true,
            completed: false,
            customUpcomingLength: nil,
            sortOrder: nil,
            isCustom: false,
            conditionsJSON: nil,
            actionsJSON: nil
        )
        return UpcomingScheduleEntry(schedule: schedule, date: date, runningBalance: nil)
    }

    @Test func budgetTransactionScopesExcludeClosedAccounts() {
        let accounts = [
            makeAccount("on", offBudget: false, sortOrder: 0),
            makeAccount("off", offBudget: true, sortOrder: 1),
            makeAccount("closed-on", offBudget: false, closed: true, sortOrder: 2),
            makeAccount("closed-off", offBudget: true, closed: true, sortOrder: 3),
        ]

        #expect(AccountTransactionsScope.onBudget.accountIds(in: accounts) == ["on"])
        #expect(AccountTransactionsScope.offBudget.accountIds(in: accounts) == ["off"])
    }

    @Test func upcomingScheduleEntriesAreFilteredToBudgetScope() {
        let accounts = [
            makeAccount("on", offBudget: false, sortOrder: 0),
            makeAccount("off", offBudget: true, sortOrder: 1),
            makeAccount("closed-on", offBudget: false, closed: true, sortOrder: 2),
        ]
        let entries = [
            makeUpcomingEntry("on-entry", accountId: "on"),
            makeUpcomingEntry("off-entry", accountId: "off"),
            makeUpcomingEntry("closed-entry", accountId: "closed-on"),
            makeUpcomingEntry("unscoped-entry", accountId: nil),
            makeUpcomingEntry("unknown-entry", accountId: "missing-account"),
        ]

        #expect(
            AccountTransactionsScope.onBudget.scoped(entries, accounts: accounts).map(\.id)
                == ["on-entry"]
        )
        #expect(
            AccountTransactionsScope.offBudget.scoped(entries, accounts: accounts).map(\.id)
                == ["off-entry"]
        )
    }

    @Test func upcomingSchedulesKeepAllAccountsOutOfTheEmptyState() {
        #expect(!TransactionsListView.showsEmptyState(
            transactionsEmpty: true,
            isLoading: false,
            isSearching: false,
            statusFilter: .all,
            schedulesLoaded: true,
            hasUpcomingSchedules: true
        ))
    }

    @Test func emptyStateRemainsForSearchesAndFilteredRegisters() {
        #expect(TransactionsListView.showsEmptyState(
            transactionsEmpty: true,
            isLoading: false,
            isSearching: true,
            statusFilter: .all,
            schedulesLoaded: true,
            hasUpcomingSchedules: true
        ))
        #expect(TransactionsListView.showsEmptyState(
            transactionsEmpty: true,
            isLoading: false,
            isSearching: false,
            statusFilter: .cleared,
            schedulesLoaded: true,
            hasUpcomingSchedules: true
        ))
    }

    @Test func searchAndFilterEmptyStatesDoNotWaitForSchedulesToLoad() {
        #expect(TransactionsListView.showsEmptyState(
            transactionsEmpty: true,
            isLoading: false,
            isSearching: true,
            statusFilter: .all,
            schedulesLoaded: false,
            hasUpcomingSchedules: false
        ))
        #expect(TransactionsListView.showsEmptyState(
            transactionsEmpty: true,
            isLoading: false,
            isSearching: false,
            statusFilter: .cleared,
            schedulesLoaded: false,
            hasUpcomingSchedules: false
        ))
    }

    @Test func emptyStateWaitsForSchedulesToLoad() {
        #expect(!TransactionsListView.showsEmptyState(
            transactionsEmpty: true,
            isLoading: false,
            isSearching: false,
            statusFilter: .all,
            schedulesLoaded: false,
            hasUpcomingSchedules: false
        ))
    }

    @Test func scheduleLoadFailureHasItsOwnEmptyState() {
        #expect(TransactionsListView.showsScheduleLoadFailure(
            transactionsEmpty: true,
            isLoading: false,
            schedulesLoaded: true,
            scheduleLoadFailed: true
        ))
        #expect(!TransactionsListView.showsScheduleLoadFailure(
            transactionsEmpty: false,
            isLoading: false,
            schedulesLoaded: true,
            scheduleLoadFailed: true
        ))
    }

    @Test(arguments: [false, true])
    func hidingSchedulesDoesNotWaitForThemOrSuppressTheEmptyState(loaded: Bool) {
        #expect(TransactionsListView.showsEmptyState(
            transactionsEmpty: true, isLoading: false, isSearching: false, statusFilter: .all,
            schedulesLoaded: loaded, hasUpcomingSchedules: true, showUpcomingSchedules: false
        ))
        #expect(!TransactionsListView.showsScheduleLoadFailure(
            transactionsEmpty: true, isLoading: false, schedulesLoaded: loaded,
            scheduleLoadFailed: true, showUpcomingSchedules: false
        ))
        #expect(!TransactionsListView.showsEmptyState(
            transactionsEmpty: false, isLoading: false, isSearching: false, statusFilter: .all,
            schedulesLoaded: loaded, hasUpcomingSchedules: true, showUpcomingSchedules: false
        ))
    }
}
