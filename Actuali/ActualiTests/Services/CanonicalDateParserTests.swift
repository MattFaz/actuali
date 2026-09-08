import Foundation
import Testing
@testable import Actuali

struct CanonicalDateParserTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func components(of date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: date)
    }

    @Test func parseAcceptsCanonicalFormsWithExpectedDefaults() throws {
        let expected: [(String, Int, Int, Int)] = [
            ("2026", 2026, 1, 1),
            ("2026-07", 2026, 7, 1),
            ("2026-07-14", 2026, 7, 14)
        ]

        for (input, year, month, day) in expected {
            let date = try #require(CanonicalDateParser.parse(input))
            let parsed = components(of: date)
            #expect(parsed.year == year)
            #expect(parsed.month == month)
            #expect(parsed.day == day)
        }
    }

    @Test func parseValidatesCalendarDates() throws {
        let leapDay = try #require(CanonicalDateParser.parse("2024-02-29"))
        let parsed = components(of: leapDay)
        #expect(parsed.year == 2024)
        #expect(parsed.month == 2)
        #expect(parsed.day == 29)

        for input in ["2023-02-29", "2024-13-01", "2024-04-31", "2024-00-01", "2024-01-00"] {
            #expect(CanonicalDateParser.parse(input) == nil)
        }
    }

    @Test func parseRejectsNonCanonicalInput() {
        let invalidInputs = [
            "26", "202", "20260", "2026-7", "2026-007", "2026-7-14", "2026-07-1",
            "2026-07-014", "2026/07/14", "2026\u{2013}07\u{2013}14", "2026-07-14x",
            "2026-07-14-", "2026-", "-07", "2026--07", "2026-07-14\n", "２０２６-０７-１４"
        ]

        for input in invalidInputs {
            #expect(CanonicalDateParser.parse(input) == nil)
        }
    }

    @Test func parseMonthOrDayRequiresMonthOrDayForm() {
        #expect(CanonicalDateParser.parseMonthOrDay("2026") == nil)

        for input in ["2026-07", "2026-07-14"] {
            #expect(CanonicalDateParser.parseMonthOrDay(input) != nil)
        }
    }

    @Test func parseMonthStartNormalizesMonthAndDayInputs() throws {
        for input in ["2026-07", "2026-07-14"] {
            let date = try #require(CanonicalDateParser.parseMonthStart(input))
            let parsed = components(of: date)
            #expect(parsed.year == 2026)
            #expect(parsed.month == 7)
            #expect(parsed.day == 1)
        }

        for input in ["2026", "2026-7", "2026-07-32", "2026/07"] {
            #expect(CanonicalDateParser.parseMonthStart(input) == nil)
        }
    }

    @Test func monthAndDayParsersRejectInvalidDates() {
        for input in ["2024-02-30", "2024-13"] {
            #expect(CanonicalDateParser.parseMonthOrDay(input) == nil)
            #expect(CanonicalDateParser.parseMonthStart(input) == nil)
        }
    }
}