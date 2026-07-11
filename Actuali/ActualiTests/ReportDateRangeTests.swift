import Foundation
import Testing
@testable import Actuali

struct ReportDateRangeTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private var today: Date { date(2026, 7, 11) }

    @Test func allTimeSpansTransactionHistory() {
        let (s, e) = ReportDateRange.resolve(
            dateRange: "All time", dateStatic: false, startDate: nil, endDate: nil,
            includeCurrent: true, earliest: date(2025, 8, 30), latest: date(2026, 7, 3),
            today: today, firstDayOfWeekIdx: 0)
        #expect(s == date(2025, 8, 30))
        #expect(e == date(2026, 7, 3))
    }

    @Test func yearToDateClampsToEarliest() {
        let (s, e) = ReportDateRange.resolve(
            dateRange: "Year to date", dateStatic: false, startDate: nil, endDate: nil,
            includeCurrent: true, earliest: date(2026, 3, 5), latest: date(2026, 7, 3),
            today: today, firstDayOfWeekIdx: 0)
        #expect(s == date(2026, 3, 5))
        #expect(e == today)
    }

    @Test func lastThreeMonthsIncludingCurrent() {
        let (s, e) = ReportDateRange.resolve(
            dateRange: "Last 3 months", dateStatic: false, startDate: nil, endDate: nil,
            includeCurrent: true, earliest: date(2024, 1, 1), latest: date(2026, 7, 3),
            today: today, firstDayOfWeekIdx: 0)
        #expect(s == date(2026, 4, 1))
        #expect(e == date(2026, 7, 31))
    }

    @Test func lastThreeMonthsExcludingCurrent() {
        let (s, e) = ReportDateRange.resolve(
            dateRange: "Last 3 months", dateStatic: false, startDate: nil, endDate: nil,
            includeCurrent: false, earliest: date(2024, 1, 1), latest: date(2026, 7, 3),
            today: today, firstDayOfWeekIdx: 0)
        #expect(s == date(2026, 4, 1))
        #expect(e == date(2026, 6, 30))
    }

    @Test func staticRangeUsesStoredDates() {
        let (s, e) = ReportDateRange.resolve(
            dateRange: nil, dateStatic: true, startDate: "2025-10-01", endDate: "2026-01-31",
            includeCurrent: true, earliest: date(2024, 1, 1), latest: date(2026, 7, 3),
            today: today, firstDayOfWeekIdx: 0)
        #expect(s == date(2025, 10, 1))
        #expect(e == date(2026, 1, 31))
    }

    @Test func unknownRangeFallsBackToAllTime() {
        let (s, e) = ReportDateRange.resolve(
            dateRange: "Bizarro range", dateStatic: false, startDate: nil, endDate: nil,
            includeCurrent: true, earliest: date(2025, 1, 2), latest: date(2026, 7, 3),
            today: today, firstDayOfWeekIdx: 0)
        #expect(s == date(2025, 1, 2))
        #expect(e == date(2026, 7, 3))
    }

    @Test func weekStartRespectsFirstDayIndex() {
        // 2026-07-01 is a Wednesday.
        #expect(ReportDateRange.weekStart(of: date(2026, 7, 1), firstDayOfWeekIdx: 0) == date(2026, 6, 28)) // Sunday
        #expect(ReportDateRange.weekStart(of: date(2026, 7, 1), firstDayOfWeekIdx: 1) == date(2026, 6, 29)) // Monday
        #expect(ReportDateRange.weekStart(of: date(2026, 6, 28), firstDayOfWeekIdx: 0) == date(2026, 6, 28)) // already Sunday
    }
}
