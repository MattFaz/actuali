import Foundation
import Testing
@testable import Actuali

/// Pins the recurrence wording against loot-core `getRecurringDescription`.
/// The monthly-pattern ordering rules are the fragile part: weekday patterns
/// sort ahead of day-of-month ones, "last" always lands at the end, and a
/// single repeated weekday is factored out of the list.
struct ScheduleDescriptionTests {

    private func config(_ json: [String: Any]) -> RecurConfig {
        var merged: [String: Any] = ["frequency": "monthly", "start": "2026-08-13"]
        merged.merge(json) { _, new in new }
        return RecurConfig(json: merged)!
    }

    @Test func daily() {
        #expect(ScheduleDescription.recurring(config(["frequency": "daily"])) == "Every day")
        #expect(ScheduleDescription.recurring(
            config(["frequency": "daily", "interval": 3])) == "Every 3 days")
    }

    @Test func weekly() {
        // 2026-08-13 is a Thursday.
        #expect(ScheduleDescription.recurring(
            config(["frequency": "weekly"])) == "Every week on Thursday")
        #expect(ScheduleDescription.recurring(
            config(["frequency": "weekly", "interval": 2])) == "Every 2 weeks on Thursday")
    }

    @Test func monthlyWithoutPatternsUsesTheStartDay() {
        #expect(ScheduleDescription.recurring(config([:])) == "Every month on the 13th")
    }

    @Test func monthlyDayPatterns() {
        let text = ScheduleDescription.recurring(config([
            "patterns": [["type": "day", "value": 15], ["type": "day", "value": 1]]
        ]))
        #expect(text == "Every month on the 1st and 15th")
    }

    @Test func lastDaySortsToTheEnd() {
        let text = ScheduleDescription.recurring(config([
            "patterns": [["type": "day", "value": -1], ["type": "day", "value": 5]]
        ]))
        #expect(text == "Every month on the 5th and last day")
    }

    @Test func sameWeekdayIsFactoredOut() {
        let text = ScheduleDescription.recurring(config([
            "patterns": [["type": "MO", "value": 1], ["type": "MO", "value": 3]]
        ]))
        #expect(text == "Every month on the 1st and 3rd Monday")
    }

    @Test func mixedWeekdaysNameEachOne() {
        let text = ScheduleDescription.recurring(config([
            "patterns": [["type": "MO", "value": 1], ["type": "FR", "value": 2]]
        ]))
        #expect(text == "Every month on the 1st Monday and 2nd Friday")
    }

    @Test func threeOrMorePartsUseAnOxfordList() {
        let text = ScheduleDescription.recurring(config([
            "patterns": [
                ["type": "day", "value": 1],
                ["type": "day", "value": 10],
                ["type": "day", "value": 20],
            ]
        ]))
        #expect(text == "Every month on the 1st, 10th, and 20th")
    }

    @Test func yearly() {
        #expect(ScheduleDescription.recurring(
            config(["frequency": "yearly"])) == "Every year on Aug 13th")
    }

    @Test func endModeSuffixes() {
        #expect(ScheduleDescription.recurring(config([
            "frequency": "daily", "endMode": "after_n_occurrences", "endOccurrences": 1
        ])) == "Every day, once")

        #expect(ScheduleDescription.recurring(config([
            "frequency": "daily", "endMode": "after_n_occurrences", "endOccurrences": 5
        ])) == "Every day, 5 times")
    }

    @Test func weekendSuffix() {
        let text = ScheduleDescription.recurring(config([
            "frequency": "daily", "skipWeekend": true, "weekendSolveMode": "before"
        ]))
        #expect(text == "Every day (before weekend)")
    }
}
