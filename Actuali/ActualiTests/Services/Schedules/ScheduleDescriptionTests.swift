import Foundation
import Testing
@testable import Actuali

/// Pins the recurrence wording against loot-core `getRecurringDescription`.
/// The monthly-pattern ordering rules are the fragile part: weekday patterns
/// sort ahead of day-of-month ones, "last" always lands at the end, and a
/// single repeated weekday is factored out of the list.
struct ScheduleDescriptionTests {

    private var appBundle: Bundle {
        Bundle(identifier: "com.mfazz.ActualiOS") ?? .main
    }

    private func config(_ json: [String: Any]) -> RecurConfig {
        var merged: [String: Any] = ["frequency": "monthly", "start": "2026-08-13"]
        merged.merge(json) { _, new in new }
        return RecurConfig(json: merged)!
    }
    
    private func pattern(_ type: String, _ value: Int) -> [String: Any] {
        ["type": type, "value": value]
    }

    @Test func daily() {
        #expect(ScheduleDescription.recurring(config(["frequency": "daily"])) == "Every 1 day")
        #expect(ScheduleDescription.recurring(
            config(["frequency": "daily", "interval": 3])) == "Every 3 days")
    }

    @Test func weekly() {
        // 2026-08-13 is a Thursday.
        #expect(ScheduleDescription.recurring(
            config(["frequency": "weekly"])) == "Every 1 week on Thursday")
        #expect(ScheduleDescription.recurring(
            config(["frequency": "weekly", "interval": 2])) == "Every 2 weeks on Thursday")
    }

    @Test func monthlyWithoutPatternsUsesTheStartDay() {
        #expect(ScheduleDescription.recurring(config([:])) == "Every 1 month on the 13th")
    }

    @Test func monthlyDayPatterns() {
        let text = ScheduleDescription.recurring(config([
            "patterns": [["type": "day", "value": 15], ["type": "day", "value": 1]]
        ]))
        #expect(text == "Every 1 month on the 1st and 15th")
    }

    @Test func lastDaySortsToTheEnd() {
        let text = ScheduleDescription.recurring(config([
            "patterns": [["type": "day", "value": -1], ["type": "day", "value": 5]]
        ]))
        #expect(text == "Every 1 month on the 5th and last day")
    }

    @Test func sameWeekdayIsFactoredOut() {
        let text = ScheduleDescription.recurring(config([
            "patterns": [["type": "MO", "value": 1], ["type": "MO", "value": 3]]
        ]))
        #expect(text == "Every 1 month on the 1st and 3rd Monday")
    }

    @Test func lastWeekdayDoesNotRepeatTheWeekdayName() {
        let text = ScheduleDescription.recurring(config([
            "patterns": [["type": "MO", "value": 1], ["type": "MO", "value": -1]]
        ]))
        #expect(text == "Every 1 month on the 1st and last Monday")
    }

    @Test func mixedWeekdaysNameEachOne() {
        let text = ScheduleDescription.recurring(config([
            "patterns": [["type": "MO", "value": 1], ["type": "FR", "value": 2]]
        ]))
        #expect(text == "Every 1 month on the 1st Monday and 2nd Friday")
    }

    @Test func threeOrMorePartsUseAnOxfordList() {
        let text = ScheduleDescription.recurring(config([
            "patterns": [
                ["type": "day", "value": 1],
                ["type": "day", "value": 10],
                ["type": "day", "value": 20],
            ]
        ]))
        #expect(text == "Every 1 month on the 1st, 10th, and 20th")
    }

    @Test func yearly() {
        #expect(ScheduleDescription.recurring(
            config(["frequency": "yearly"])) == "Every 1 year on Aug 13")
    }

    @Test func endModeSuffixes() {
        #expect(ScheduleDescription.recurring(config([
            "frequency": "daily", "endMode": "after_n_occurrences", "endOccurrences": 1
        ])) == "Every 1 day, 1 time")

        #expect(ScheduleDescription.recurring(config([
            "frequency": "daily", "endMode": "after_n_occurrences", "endOccurrences": 5
        ])) == "Every 1 day, 5 times")
    }

    @Test func countBearingRecurrenceTextUsesRequestedLocale() {
        let cases = [
            (Locale(identifier: "en_US"), ["Every 1 day, 1 time", "Every 1 day, 2 times", "Every 2 days"]),
            (Locale(identifier: "fr_FR"), ["Tous les 1 jour, 1 fois", "Tous les 1 jour, 2 fois", "Tous les 2 jours"]),
            (Locale(identifier: "pt_BR"), ["A cada 1 dia, 1 vez", "A cada 1 dia, 2 vezes", "A cada 2 dias"])
        ]

        for (locale, values) in cases {
            #expect(ScheduleDescription.recurring(config([
                "frequency": "daily", "endMode": "after_n_occurrences", "endOccurrences": 1
            ]), locale: locale, bundle: appBundle) == values[0])
            #expect(ScheduleDescription.recurring(config([
                "frequency": "daily", "endMode": "after_n_occurrences", "endOccurrences": 2
            ]), locale: locale, bundle: appBundle) == values[1])
            #expect(ScheduleDescription.recurring(config([
                "frequency": "daily", "interval": 2
            ]), locale: locale, bundle: appBundle) == values[2])
        }
    }

    @Test func weekendSuffix() {
        let text = ScheduleDescription.recurring(config([
            "frequency": "daily", "skipWeekend": true, "weekendSolveMode": "before"
        ]))
        #expect(text == "Every 1 day (before weekend)")
    }

    @Test func localizedWeekdayAndMonthNamesUseTheRequestedLocale() {
        let french = Locale(identifier: "fr_FR")
        #expect(ScheduleDescription.weekdayName(forCode: "TH", locale: french) == "jeudi")
        #expect(ScheduleDescription.shortMonthName(8, locale: french) == "août")
    }
}
