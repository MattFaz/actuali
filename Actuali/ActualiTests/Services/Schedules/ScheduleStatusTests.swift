import Foundation
import Testing
@testable import Actuali

/// Pins the status engine against loot-core `getStatus` / `getUpcomingDays`.
/// The badge on the phone and the badge on the web have to agree, so the
/// branch order and the window arithmetic are both load-bearing.
struct ScheduleStatusTests {

    private static let today = DayDate(yyyymmdd: 20260813)!   // Thu 13 Aug 2026

    private func status(
        next: Int?,
        completed: Bool = false,
        hasTransaction: Bool = false,
        upcomingLength: String? = nil
    ) -> ScheduleStatus {
        ScheduleStatusCalculator.status(
            nextDate: next.flatMap { DayDate(yyyymmdd: $0) },
            completed: completed,
            hasTransaction: hasTransaction,
            upcomingLength: upcomingLength,
            today: Self.today)
    }

    @Test func completedWinsOverEverything() {
        #expect(status(next: 20260813, completed: true, hasTransaction: true) == .completed)
        // Even a missed date reads as completed once the schedule is finished.
        #expect(status(next: 20250101, completed: true) == .completed)
    }

    @Test func paidWinsOverDate() {
        #expect(status(next: 20260813, hasTransaction: true) == .paid)
        #expect(status(next: 20250101, hasTransaction: true) == .paid)
    }

    @Test func dueIsExactlyToday() {
        #expect(status(next: 20260813) == .due)
    }

    @Test func upcomingIsInsideTheWindowInclusive() {
        #expect(status(next: 20260814) == .upcoming)
        #expect(status(next: 20260820) == .upcoming)   // today + 7, inclusive
        #expect(status(next: 20260821) == .scheduled)  // one day past the window
    }

    @Test func missedIsAnyPastDate() {
        #expect(status(next: 20260812) == .missed)
        #expect(status(next: 20250101) == .missed)
    }

    /// A schedule with no readable next-date row still has to render.
    @Test func missingNextDateFallsBackToScheduled() {
        #expect(status(next: nil) == .scheduled)
    }

    // MARK: - Upcoming window

    @Test func literalDayCounts() {
        #expect(ScheduleUpcomingLength.days(for: nil, today: Self.today) == 7)
        #expect(ScheduleUpcomingLength.days(for: "", today: Self.today) == 7)
        #expect(ScheduleUpcomingLength.days(for: "30", today: Self.today) == 30)
    }

    @Test func currentMonthRunsToTheEndOfTheMonth() {
        // August has 31 days; 31 - 13 = 18.
        #expect(ScheduleUpcomingLength.days(for: "currentMonth", today: Self.today) == 18)
    }

    @Test func oneMonthIsTheLengthOfTheCurrentMonth() {
        // Measured from the 1st, per upstream: 1 Aug -> 1 Sep = 31 days.
        #expect(ScheduleUpcomingLength.days(for: "oneMonth", today: Self.today) == 31)
    }

    @Test func compoundForms() {
        #expect(ScheduleUpcomingLength.days(for: "3-day", today: Self.today) == 3)
        #expect(ScheduleUpcomingLength.days(for: "2-week", today: Self.today) == 14)
        // Upstream measures month/year windows from the 1st and adds one.
        #expect(ScheduleUpcomingLength.days(for: "1-month", today: Self.today) == 44)
    }

    @Test func unparseableValuesFallBackRatherThanBreaking() {
        #expect(ScheduleUpcomingLength.days(for: "nonsense", today: Self.today) == 7)
        #expect(ScheduleUpcomingLength.days(for: "2-fortnight", today: Self.today) == 7)
    }

    // MARK: - Occurrence match window

    @Test func exactAndAutoPostingSchedulesGetNoLookback() {
        let next = DayDate(yyyymmdd: 20260813)!
        #expect(ScheduleStatusCalculator.occurrenceMatchStartDate(
            nextDate: next, dateOp: "is", postsTransaction: false) == next)
        #expect(ScheduleStatusCalculator.occurrenceMatchStartDate(
            nextDate: next, dateOp: "isapprox", postsTransaction: true) == next)
    }

    @Test func manualApproximateSchedulesAllowTwoDaysEarly() {
        let next = DayDate(yyyymmdd: 20260813)!
        #expect(ScheduleStatusCalculator.occurrenceMatchStartDate(
            nextDate: next, dateOp: "isapprox", postsTransaction: false)
            == DayDate(yyyymmdd: 20260811)!)
    }
}
