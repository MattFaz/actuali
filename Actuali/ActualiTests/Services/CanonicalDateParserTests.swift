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

    @Test(arguments: [
        ("2026", 2026, 1, 1),
        ("2026-07", 2026, 7, 1),
        ("2026-07-14", 2026, 7, 14),
        ("2024-02-29", 2024, 2, 29),
    ])
    func parseAcceptsCanonicalFormsWithExpectedDefaults(input: String, year: Int, month: Int, day: Int) throws {
        let date = try #require(CanonicalDateParser.parse(input))
        let parsed = components(of: date)
        #expect(parsed.year == year)
        #expect(parsed.month == month)
        #expect(parsed.day == day)
    }

    @Test(arguments: ["2023-02-29", "2024-13-01", "2024-04-31", "2024-00-01", "2024-01-00"])
    func parseValidatesCalendarDates(input: String) {
        #expect(CanonicalDateParser.parse(input) == nil)
    }

    @Test(arguments: [
        "26", "202", "20260", "2026-7", "2026-007", "2026-7-14", "2026-07-1",
        "2026-07-014", "2026/07/14", "2026\u{2013}07\u{2013}14", "2026-07-14x",
        "2026-07-14-", "2026-", "-07", "2026--07", "2026-07-14\n", "２０２６-０７-１４",
    ])
    func parseRejectsNonCanonicalInput(input: String) {
        #expect(CanonicalDateParser.parse(input) == nil)
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

    @Test(arguments: ["2024-02-30", "2024-13"])
    func monthAndDayParsersRejectInvalidDates(input: String) {
        #expect(CanonicalDateParser.parseMonthOrDay(input) == nil)
        #expect(CanonicalDateParser.parseMonthStart(input) == nil)
    }
}
