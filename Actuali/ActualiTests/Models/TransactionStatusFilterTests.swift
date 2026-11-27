import Testing
@testable import Actuali

struct TransactionStatusFilterTests {
    @Test func upcomingSchedulesAreRelevantOnlyToAllUnclearedAndUnreconciled() {
        let eligibleFilters = TransactionStatusFilter.allCases.filter(\.includesUpcomingSchedules)
        #expect(eligibleFilters == [.all, .uncleared, .unreconciled])
    }
}
