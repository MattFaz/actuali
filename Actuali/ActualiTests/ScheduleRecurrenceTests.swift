import Foundation
import Testing
@testable import Actuali

struct ScheduleRecurrenceTests {

    private struct Fixture {
        let name: String
        let config: [String: Any]
        let queryDate: String
        let expected: String?
    }

    private static func loadFixtures() throws -> [Fixture] {
        let data = Data(recurrenceFixturesJSON.utf8)
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let array = raw as? [[String: Any]] else {
            throw NSError(domain: "ScheduleRecurrenceTests", code: 1)
        }
        return array.map { obj in
            Fixture(
                name: obj["name"] as? String ?? "<unnamed>",
                config: obj["config"] as? [String: Any] ?? [:],
                queryDate: obj["queryDate"] as? String ?? "",
                expected: obj["expected"] as? String
            )
        }
    }

    @Test func allFixturesMatchLootCore() throws {
        let fixtures = try Self.loadFixtures()
        #expect(fixtures.count == 45)
        for f in fixtures {
            guard let config = RecurConfig(json: f.config) else {
                Issue.record("case \(f.name): config failed to parse")
                continue
            }
            guard let target = DayDate(iso: f.queryDate) else {
                Issue.record("case \(f.name): queryDate failed to parse")
                continue
            }
            let result = ScheduleRecurrence.nextOccurrence(config: config, onOrAfter: target)
            #expect(
                result?.iso == f.expected,
                "case \(f.name): got \(result?.iso ?? "nil"), want \(f.expected ?? "nil")"
            )
        }
    }

    // MARK: - RecurConfig robustness

    @Test func configRejectsUnknownFrequency() {
        #expect(RecurConfig(json: ["frequency": "hourly", "start": "2026-01-01"]) == nil)
    }

    @Test func configRejectsMissingOrUnparseableStart() {
        #expect(RecurConfig(json: ["frequency": "daily"]) == nil)
        #expect(RecurConfig(json: ["frequency": "daily", "start": "garbage"]) == nil)
        #expect(RecurConfig(json: ["frequency": "daily", "start": "2026-13-01"]) == nil)
    }

    @Test func configRejectsMalformedPatterns() {
        let badType: [String: Any] = [
            "frequency": "monthly", "start": "2026-01-01",
            "patterns": [["type": "XX", "value": 1]],
        ]
        #expect(RecurConfig(json: badType) == nil)
        let missingValue: [String: Any] = [
            "frequency": "monthly", "start": "2026-01-01",
            "patterns": [["type": "day"]],
        ]
        #expect(RecurConfig(json: missingValue) == nil)
    }

    @Test func configRejectsOutOfRangePatternValues() {
        func config(patterns: [[String: Any]]) -> RecurConfig? {
            RecurConfig(json: ["frequency": "monthly", "start": "2026-01-01", "patterns": patterns])
        }
        #expect(config(patterns: [["type": "TU", "value": 0]]) == nil)   // nth=0 weekday
        #expect(config(patterns: [["type": "day", "value": 0]]) == nil)
        #expect(config(patterns: [["type": "day", "value": 32]]) == nil)
        #expect(config(patterns: [["type": "day", "value": -32]]) == nil)
        #expect(config(patterns: [["type": "MO", "value": 6]]) == nil)
        #expect(config(patterns: [["type": "MO", "value": -6]]) == nil)
    }

    @Test func configRejectsBoundedEndModeWithoutBound() {
        #expect(RecurConfig(json: [
            "frequency": "monthly", "start": "2026-01-01", "endMode": "on_date",
        ]) == nil)
        #expect(RecurConfig(json: [
            "frequency": "monthly", "start": "2026-01-01", "endMode": "on_date", "endDate": "garbage",
        ]) == nil)
        #expect(RecurConfig(json: [
            "frequency": "monthly", "start": "2026-01-01", "endMode": "after_n_occurrences",
        ]) == nil)
        #expect(RecurConfig(json: [
            "frequency": "monthly", "start": "2026-01-01", "endMode": "after_n_occurrences", "endOccurrences": 0,
        ]) == nil)
    }

    @Test func configAcceptsValidShapes() {
        let full: [String: Any] = [
            "frequency": "monthly", "start": "2026-01-01",
            "patterns": [["type": "day", "value": -1], ["type": "FR", "value": 5], ["type": "day", "value": 31]],
            "endMode": "after_n_occurrences", "endOccurrences": 3,
        ]
        #expect(RecurConfig(json: full) != nil)
        let onDate: [String: Any] = [
            "frequency": "weekly", "start": "2026-01-07", "endMode": "on_date", "endDate": "2026-06-01",
        ]
        #expect(RecurConfig(json: onDate) != nil)
    }
}

struct DayDateTests {

    @Test func invalidInputsReturnNil() {
        #expect(DayDate(iso: "not-a-date") == nil)
        #expect(DayDate(iso: "2026-02-30") == nil)
        #expect(DayDate(iso: "2026-00-10") == nil)
        #expect(DayDate(yyyymmdd: 20260230) == nil)
        #expect(DayDate(yyyymmdd: 20261301) == nil)
    }

    @Test func parsesLongerISOStrings() {
        #expect(DayDate(iso: "2026-07-17T12:34:56Z")?.iso == "2026-07-17")
    }

    @Test func addingDaysCrossesMonthAndYearBoundaries() {
        #expect(DayDate(year: 2026, month: 1, day: 31).adding(days: 1).iso == "2026-02-01")
        #expect(DayDate(year: 2026, month: 12, day: 31).adding(days: 1).iso == "2027-01-01")
        #expect(DayDate(year: 2024, month: 2, day: 28).adding(days: 1).iso == "2024-02-29")
        #expect(DayDate(year: 2026, month: 3, day: 1).adding(days: -1).iso == "2026-02-28")
    }

    @Test func weekdayOfKnownDate() {
        // 2026-07-17 is a Friday (1 = Sunday ... 7 = Saturday).
        #expect(DayDate(year: 2026, month: 7, day: 17).weekday == 6)
        #expect(DayDate(year: 2026, month: 7, day: 18).isWeekend)
        #expect(DayDate(year: 2026, month: 7, day: 19).isWeekend)
        #expect(!DayDate(year: 2026, month: 7, day: 17).isWeekend)
    }

    @Test func yyyymmddRoundTrip() {
        let d = DayDate(yyyymmdd: 20260717)
        #expect(d?.yyyymmdd == 20260717)
        #expect(d?.iso == "2026-07-17")
        #expect(DayDate(iso: "2026-07-17")?.yyyymmdd == 20260717)
    }

    @Test func comparableOrdering() {
        #expect(DayDate(year: 2026, month: 1, day: 31) < DayDate(year: 2026, month: 2, day: 1))
        #expect(DayDate(year: 2025, month: 12, day: 31) < DayDate(year: 2026, month: 1, day: 1))
    }
}
