import Testing
@testable import Actuali

struct TransactionsListViewTests {
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
