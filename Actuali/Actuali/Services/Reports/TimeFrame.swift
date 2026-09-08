import Foundation

/// Resolves a widget's `WidgetTimeFrame` to a concrete `(start, end)` date range.
/// Uses UTC to match upstream behavior.
enum TimeFrame {

    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// Returns `(start, end)` for a widget's time frame. `today` is the reference
    /// "now" — production passes `Date()`, tests pass a fixed date.
    static func resolve(_ tf: WidgetTimeFrame?, asOf today: Date) -> (Date, Date) {
        guard let tf else { return currentMonth(asOf: today) }

        switch tf.mode {
        case .none:
            return currentMonth(asOf: today)
        case .slidingWindow:
            return slidingWindow(tf, asOf: today)
        case .yearToDate:
            return currentYear(asOf: today)
        case .lastMonth:
            return lastFullMonth(before: today)
        case .lastYear:
            return lastFullYear(before: today)
        case .priorYearToDate:
            return priorYearToDate(asOf: today)
        case .static:
            return staticRange(tf, asOf: today)
        case .full:
            return fullRange(tf, asOf: today)
        }
    }

    /// "Sliding window" preserves the configured window size and slides it forward
    /// each month relative to today. Stored start/end are YYYY-MM strings marking
    /// the window when configured; we compute the difference between today's
    /// month and the stored end month and shift both by that amount.
    private static func slidingWindow(_ tf: WidgetTimeFrame, asOf today: Date) -> (Date, Date) {
        guard let storedStart = parseMonth(tf.start),
              let storedEnd = parseMonth(tf.end) else {
            return currentMonth(asOf: today)
        }

        let todayMonth = monthStart(of: today)
        let monthsDiff = calendar.dateComponents([.month], from: storedEnd, to: todayMonth).month ?? 0

        guard let newStart = calendar.date(byAdding: .month, value: monthsDiff, to: storedStart),
              let newEnd = calendar.date(byAdding: .month, value: monthsDiff, to: storedEnd) else {
            return currentMonth(asOf: today)
        }

        let endLastDay = endOfMonth(newEnd)
        return (newStart, endLastDay)
    }

    private static func currentMonth(asOf today: Date) -> (Date, Date) {
        let start = monthStart(of: today)
        return (start, endOfMonth(start))
    }

    /// Parses "YYYY-MM" or "YYYY-MM-DD" to the first-of-month Date.
    private static func parseMonth(_ s: String?) -> Date? {
        guard let s else { return nil }
        return CanonicalDateParser.parseMonthStart(s)
    }

    private static func monthStart(of date: Date) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? date
    }

    private static func endOfMonth(_ monthStartDate: Date) -> Date {
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStartDate),
              let last = calendar.date(byAdding: .day, value: -1, to: nextMonth) else { return monthStartDate }
        return last
    }

    private static func currentYear(asOf today: Date) -> (Date, Date) {
        let comps = calendar.dateComponents([.year], from: today)
        let start = calendar.date(from: DateComponents(year: comps.year, month: 1, day: 1))!
        return (start, today)
    }

    private static func lastFullMonth(before today: Date) -> (Date, Date) {
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
        let lastMonthEnd = calendar.date(byAdding: .day, value: -1, to: monthStart)!
        let lastMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: lastMonthEnd))!
        return (lastMonthStart, lastMonthEnd)
    }

    private static func lastFullYear(before today: Date) -> (Date, Date) {
        let thisYearStart = calendar.date(from: DateComponents(
            year: calendar.component(.year, from: today),
            month: 1, day: 1
        ))!
        let lastYearEnd = calendar.date(byAdding: .day, value: -1, to: thisYearStart)!
        let lastYearStart = calendar.date(from: DateComponents(
            year: calendar.component(.year, from: lastYearEnd),
            month: 1, day: 1
        ))!
        return (lastYearStart, lastYearEnd)
    }

    private static func priorYearToDate(asOf today: Date) -> (Date, Date) {
        let lastYear = calendar.component(.year, from: today) - 1
        let start = calendar.date(from: DateComponents(year: lastYear, month: 1, day: 1))!
        var comps = calendar.dateComponents([.month, .day], from: today)
        comps.year = lastYear
        let end = calendar.date(from: comps)!
        return (start, end)
    }

    private static func staticRange(_ tf: WidgetTimeFrame, asOf today: Date) -> (Date, Date) {
        let start = parseRangeStart(tf.start) ?? currentMonth(asOf: today).0
        let end = parseRangeEnd(tf.end) ?? today
        return (start, end)
    }

    /// Upstream's "full" mode honors the stored start but ALWAYS uses the
    /// current month as the end (regardless of any stored end). This is why
    /// upstream's "Spent All Time" widget shows "Apr 2025 - May 2026" even
    /// when end is stored as "2026-04": the stored end is residual from when
    /// the widget was edited and is intentionally ignored.
    private static func fullRange(_ tf: WidgetTimeFrame, asOf today: Date) -> (Date, Date) {
        let defaultStart = calendar.date(from: DateComponents(year: 1900, month: 1, day: 1))!
        let start = parseRangeStart(tf.start) ?? defaultStart
        let end = endOfMonth(monthStart(of: today))
        return (start, end)
    }

    /// Parse a range start. YYYY-MM snaps to first-of-month, YYYY-MM-DD is used as-is.
    private static func parseRangeStart(_ s: String?) -> Date? {
        guard let s else { return nil }
        return CanonicalDateParser.parseMonthOrDay(s)
    }

    /// Parse a range end. YYYY-MM expands to end-of-month so the range is
    /// inclusive of the entire month, matching upstream behavior. YYYY-MM-DD
    /// is used as-is.
    private static func parseRangeEnd(_ s: String?) -> Date? {
        guard let s, let d = CanonicalDateParser.parseMonthOrDay(s) else { return nil }
        if s.count == 7 { return endOfMonth(d) }
        return d
    }
}
