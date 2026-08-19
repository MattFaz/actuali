import Foundation
import Testing
@testable import Actuali

@MainActor
struct TimeFrameTests {

    /// 2026-05-14 fixed reference date for deterministic tests (UTC).
    private var referenceDate: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 14
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func ymd(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    @Test func nilTimeFrameDefaultsToCurrentMonth() {
        // Upstream Actual defaults summary widgets to the current month when
        // no timeFrame is set.
        let (start, end) = TimeFrame.resolve(nil, asOf: referenceDate)
        #expect(ymd(start) == "2026-05-01")
        #expect(ymd(end) == "2026-05-31")
    }

    @Test func lastMonth() {
        let tf = WidgetTimeFrame(start: nil, end: nil, mode: .lastMonth)
        let (start, end) = TimeFrame.resolve(tf, asOf: referenceDate)
        #expect(ymd(start) == "2026-04-01")
        #expect(ymd(end) == "2026-04-30")
    }

    @Test func lastYear() {
        let tf = WidgetTimeFrame(start: nil, end: nil, mode: .lastYear)
        let (start, end) = TimeFrame.resolve(tf, asOf: referenceDate)
        #expect(ymd(start) == "2025-01-01")
        #expect(ymd(end) == "2025-12-31")
    }

    @Test func yearToDate() {
        let tf = WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate)
        let (start, end) = TimeFrame.resolve(tf, asOf: referenceDate)
        #expect(ymd(start) == "2026-01-01")
        #expect(ymd(end) == "2026-05-14")
    }

    @Test func priorYearToDate() {
        let tf = WidgetTimeFrame(start: nil, end: nil, mode: .priorYearToDate)
        let (start, end) = TimeFrame.resolve(tf, asOf: referenceDate)
        #expect(ymd(start) == "2025-01-01")
        #expect(ymd(end) == "2025-05-14")
    }

    @Test func staticUsesProvidedFullDates() {
        let tf = WidgetTimeFrame(start: "2024-03-01", end: "2024-04-15", mode: .static)
        let (start, end) = TimeFrame.resolve(tf, asOf: referenceDate)
        #expect(ymd(start) == "2024-03-01")
        #expect(ymd(end) == "2024-04-15")
    }

    @Test func staticAcceptsYearMonthFormat() {
        // The webapp stores most timeFrames as YYYY-MM (e.g., "2025-08" /
        // "2026-04"). Start snaps to month start, end expands to month end.
        let tf = WidgetTimeFrame(start: "2025-08", end: "2026-04", mode: .static)
        let (start, end) = TimeFrame.resolve(tf, asOf: referenceDate)
        #expect(ymd(start) == "2025-08-01")
        #expect(ymd(end) == "2026-04-30")
    }

    @Test func fullWithNilBoundsReturnsWideRange() {
        let tf = WidgetTimeFrame(start: nil, end: nil, mode: .full)
        let (start, end) = TimeFrame.resolve(tf, asOf: referenceDate)
        #expect(ymd(start) == "1900-01-01")
        #expect(ymd(end) == "2026-05-31")
    }

    @Test func fullHonorsStoredStart() {
        let tf = WidgetTimeFrame(start: "2025-04", end: nil, mode: .full)
        let (start, _) = TimeFrame.resolve(tf, asOf: referenceDate)
        #expect(ymd(start) == "2025-04-01")
    }

    @Test func fullIgnoresStoredEnd() {
        // mode=full uses current-month end regardless of any stored end.
        // This matches upstream's getFullRange semantics: the stored end is
        // residual from when the widget was edited.
        let tf = WidgetTimeFrame(start: "2025-04", end: "2026-04", mode: .full)
        let (start, end) = TimeFrame.resolve(tf, asOf: referenceDate)
        #expect(ymd(start) == "2025-04-01")
        #expect(ymd(end) == "2026-05-31")
    }

    @Test func slidingWindowWithoutBoundsDefaultsToCurrentMonth() {
        let tf = WidgetTimeFrame(start: nil, end: nil, mode: .slidingWindow)
        let (start, end) = TimeFrame.resolve(tf, asOf: referenceDate)
        #expect(ymd(start) == "2026-05-01")
        #expect(ymd(end) == "2026-05-31")
    }

    @Test func slidingWindowOneMonthSlidesForward() {
        // A 1-month window stored as April 2026 -> April 2026, when today is
        // May 14 2026, slides to May 2026 -> May 31 2026. Matches upstream's
        // sliding-window semantics: shift by the months between today and the
        // stored end.
        let tf = WidgetTimeFrame(start: "2026-04", end: "2026-04", mode: .slidingWindow)
        let (start, end) = TimeFrame.resolve(tf, asOf: referenceDate)
        #expect(ymd(start) == "2026-05-01")
        #expect(ymd(end) == "2026-05-31")
    }

    @Test func slidingWindowThreeMonthsSlidesForward() {
        // 3-month window stored Feb 2026 -> Apr 2026, today May 14 2026.
        // Shift by 1 month: Mar 2026 -> May 31 2026.
        let tf = WidgetTimeFrame(start: "2026-02", end: "2026-04", mode: .slidingWindow)
        let (start, end) = TimeFrame.resolve(tf, asOf: referenceDate)
        #expect(ymd(start) == "2026-03-01")
        #expect(ymd(end) == "2026-05-31")
    }
}
