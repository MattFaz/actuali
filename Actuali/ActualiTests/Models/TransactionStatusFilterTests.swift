import Testing
@testable import Actuali

struct TransactionStatusFilterTests {
    @Test func upcomingSchedulesAreRelevantOnlyToAllUnclearedAndUnreconciled() {
        let eligibleFilters = TransactionStatusFilter.allCases.filter { $0.includesUpcomingSchedules }
        #expect(eligibleFilters == [.all, .uncleared, .unreconciled])
    }
}
