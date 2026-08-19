import Foundation
import Testing
@testable import Actuali

/// Pins the pure parts of the lifecycle actions. The skip rule's weekend case
/// is the one with real teeth: without it, skipping a "move before weekend"
/// schedule silently does nothing.
struct ScheduleLifecycleTests {

    private func config(_ json: [String: Any]) -> RecurConfig {
        var merged: [String: Any] = ["frequency": "monthly", "start": "2026-01-15"]
        merged.merge(json) { _, new in new }
        return RecurConfig(json: merged)!
    }

    /// The production rule `skipScheduleNextDate` searches from — not a copy
    /// of it, so a change to the rule breaks these tests.
    private func searchStart(next: DayDate, config: RecurConfig) -> DayDate {
        ScheduleRecurrence.skipSearchStart(from: next, config: config)
    }

    @Test func ordinarySkipSearchesFromTheDayAfter() {
        let next = DayDate(yyyymmdd: 20260815)!   // Saturday, no weekend solve
        let plain = config([:])
        #expect(searchStart(next: next, config: plain) == DayDate(yyyymmdd: 20260816))
    }

    /// A Friday occurrence under "before" solving is really the weekend
    /// occurrence pulled back; searching from Saturday would re-find it.
    @Test func skipStepsClearOfABeforeWeekendSolve() {
        let friday = DayDate(yyyymmdd: 20260814)!   // Friday
        let solved = config(["skipWeekend": true, "weekendSolveMode": "before"])
        #expect(friday.weekday == 6)
        // Jumps to Monday 17th, then searches from the 18th.
        #expect(searchStart(next: friday, config: solved) == DayDate(yyyymmdd: 20260818))
    }

    @Test func afterWeekendSolvingNeedsNoSpecialCase() {
        let friday = DayDate(yyyymmdd: 20260814)!
        let solved = config(["skipWeekend": true, "weekendSolveMode": "after"])
        #expect(searchStart(next: friday, config: solved) == DayDate(yyyymmdd: 20260815))
    }

    @Test func skippingAMonthlyScheduleLandsOnTheFollowingMonth() {
        let plain = config([:])
        let next = try! #require(ScheduleRecurrence.nextOccurrence(
            config: plain, onOrAfter: DayDate(yyyymmdd: 20260816)!))
        #expect(next == DayDate(yyyymmdd: 20260915))
    }

    @Test func postAmountAveragesARange() {
        var schedule = ScheduleSummary(
            id: "s1", name: nil, ruleId: "r1", nextDate: DayDate(yyyymmdd: 20260815),
            nextDateRowId: "nd1", baseNextDateTs: 1, accountId: "acct-1",
            payeeId: nil, amount: .range(-1200, -1000), amountOp: .isBetween,
            dateOp: "isapprox", dateCondition: nil, postsTransaction: false,
            completed: false, customUpcomingLength: nil, sortOrder: nil,
            isCustom: false, conditionsJSON: nil, actionsJSON: nil)
        #expect(schedule.postAmount == -1100)

        schedule.amount = nil
        // A schedule with no amount condition posts zero, not a crash.
        #expect(schedule.postAmount == 0)
    }
}
