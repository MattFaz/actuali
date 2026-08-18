import Foundation
import Testing
@testable import Actuali

/// Pins the editor's occurrence preview. The termination rules matter most:
/// a bounded recurrence must stop rather than repeat its final date, which is
/// how `nextOccurrence` reports exhaustion.
struct ScheduleUpcomingDatesTests {

    private static let today = DayDate(yyyymmdd: 20260813)!

    private func config(_ json: [String: Any]) -> RecurConfig {
        var merged: [String: Any] = ["frequency": "monthly", "start": "2026-01-15"]
        merged.merge(json) { _, new in new }
        return RecurConfig(json: merged)!
    }
    
    private func pattern(_ type: String, _ value: Int) -> [String: Any] {
        ["type": type, "value": value]
    }

    @Test func listsSuccessiveMonthlyOccurrences() {
        let dates = ScheduleRecurrence.upcomingDates(
            for: config([:]), count: 4, from: Self.today)
        #expect(dates.map(\.yyyymmdd) == [20260815, 20260915, 20261015, 20261115])
    }

    @Test func respectsAnInterval() {
        let dates = ScheduleRecurrence.upcomingDates(
            for: config(["interval": 3]), count: 3, from: Self.today)
        #expect(dates.map(\.yyyymmdd) == [20261015, 20270115, 20270415])
    }

    @Test func stopsAtAnEndDateInsteadOfRepeating() {
        let dates = ScheduleRecurrence.upcomingDates(
            for: config(["endMode": "on_date", "endDate": "2026-10-20"]),
            count: 5, from: Self.today)
        #expect(dates.map(\.yyyymmdd) == [20260815, 20260915, 20261015])
    }

    @Test func stopsAfterTheOccurrenceCount() {
        // Ten monthly occurrences from 2026-01-15 end at 2026-10-15.
        let dates = ScheduleRecurrence.upcomingDates(
            for: config(["endMode": "after_n_occurrences", "endOccurrences": 10]),
            count: 5, from: Self.today)
        #expect(dates.map(\.yyyymmdd) == [20260815, 20260915, 20261015])
    }
    
    /// Once a bounded recurrence is exhausted `nextOccurrence` reports it by
    /// returning the LAST occurrence. On the first iteration there is no
    /// previous date to catch that, so an ended schedule would otherwise
    /// preview a date in the past as its next occurrence.
    @Test func anEndedRecurrenceHasNoUpcomingDates() {
        let ended = config(["endMode": "on_date", "endDate": "2026-03-20"])
        #expect(ScheduleRecurrence.upcomingDates(
            for: ended, count: 4, from: Self.today).isEmpty)
    }

    @Test func aRecurrenceOutOfOccurrencesHasNoUpcomingDates() {
        // Two monthly occurrences from 2026-01-15 end at 2026-02-15.
        let ended = config(["endMode": "after_n_occurrences", "endOccurrences": 2])
        #expect(ScheduleRecurrence.upcomingDates(
            for: ended, count: 4, from: Self.today).isEmpty)
    }

    /// The two-day slack that allows for weekend solving must not swallow a
    /// legitimate occurrence that lands just before today.
    @Test func weekendSolvingCanStillPullTheFirstDateBackwards() {
        // 2026-08-15 is a Saturday; solving "before" moves it to Friday the 14th.
        let solved = config(["skipWeekend": true, "weekendSolveMode": "before"])
        let dates = ScheduleRecurrence.upcomingDates(
            for: solved, count: 1, from: Self.today)
        #expect(dates.map(\.yyyymmdd) == [20260814])
    }

    @Test func multiplePatternsProduceMultipleDatesPerMonth() {
        let dates = ScheduleRecurrence.upcomingDates(
            for: config(["patterns": [
                ["type": "day", "value": 1],
                ["type": "day", "value": 15],
            ]]),
            count: 4, from: Self.today)
        #expect(dates.map(\.yyyymmdd) == [20260815, 20260901, 20260915, 20261001])
    }

    @Test func draftRoundTripsThroughRecurConfig() {
        let original = config(["patterns": [["type": "MO", "value": 2]],
                               "skipWeekend": true, "weekendSolveMode": "before"])
        let round = RecurrenceDraft(config: original).config
        #expect(round.frequency == original.frequency)
        #expect(round.patterns == original.patterns)
        #expect(round.skipWeekend)
        #expect(round.weekendSolveMode == "before")
    }

    @Test func draftClampsWeekdayOrdinals() {
        var draft = RecurrenceDraft(config: config([:]))
        draft.patterns = [RecurConfig.Pattern(type: "day", value: 20)]
        // There is no 20th Monday of a month.
        draft.setPatternType(at: 0, to: "MO")
        #expect(draft.patterns[0].value == RecurrenceDraft.maxWeekdayOrdinal)
    }

    @Test func draftDropsPatternsOnNonMonthlyFrequencies() {
        var draft = RecurrenceDraft(config: config([
            "patterns": [["type": "day", "value": 5]],
        ]))
        draft.frequency = .weekly
        #expect(draft.config.patterns.isEmpty)
    }
}
