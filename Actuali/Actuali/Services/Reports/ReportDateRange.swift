import Foundation

/// Resolves a custom report's date range to concrete (start, end) dates.
/// Mirrors upstream getLiveRange()/getSpecificRange() (desktop-client
/// reports). Dynamic ranges are computed relative to `today`; "All time"
/// spans the actual transaction history.
enum ReportDateRange {

    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func resolve(
        dateRange: String?,
        dateStatic: Bool,
        startDate: String?,
        endDate: String?,
        includeCurrent: Bool,
        earliest: Date?,
        latest: Date?,
        today: Date,
        firstDayOfWeekIdx: Int
    ) -> (Date, Date) {
        let allTime = (earliest ?? today, latest ?? today)

        if dateStatic {
            let s = parseRangeStart(startDate) ?? allTime.0
            let e = parseRangeEnd(endDate) ?? today
            return (s, e)
        }

        switch dateRange {
        case "All time", nil:
            return allTime
        case "Year to date":
            let jan1 = cal.date(from: DateComponents(
                year: cal.component(.year, from: today), month: 1, day: 1))!
            return (max(allTime.0, jan1), today)
        case "Prior year to date":
            let year = cal.component(.year, from: today) - 1
            let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
            var comps = cal.dateComponents([.month, .day], from: today)
            comps.year = year
            return (max(allTime.0, jan1), cal.date(from: comps)!)
        case "Last year":
            let year = cal.component(.year, from: today) - 1
            return (max(allTime.0, cal.date(from: DateComponents(year: year, month: 1, day: 1))!),
                    cal.date(from: DateComponents(year: year, month: 12, day: 31))!)
        case "Last 30 days":
            return (max(allTime.0, cal.date(byAdding: .day, value: -29, to: today)!), today)
        case "This month":
            return monthsBack(0, add: 0, today: today, earliest: allTime.0)
        case "Last month":
            return monthsBack(1, add: includeCurrent ? 1 : 0, today: today, earliest: allTime.0)
        case "Last 3 months":
            return monthsBack(3, add: includeCurrent ? 3 : 2, today: today, earliest: allTime.0)
        case "Last 6 months":
            return monthsBack(6, add: includeCurrent ? 6 : 5, today: today, earliest: allTime.0)
        case "Last 12 months":
            return monthsBack(12, add: includeCurrent ? 12 : 11, today: today, earliest: allTime.0)
        case "This week":
            let start = weekStart(of: today, firstDayOfWeekIdx: firstDayOfWeekIdx)
            return (max(allTime.0, start), cal.date(byAdding: .day, value: 6, to: start)!)
        case "Last week":
            let thisWeek = weekStart(of: today, firstDayOfWeekIdx: firstDayOfWeekIdx)
            let start = cal.date(byAdding: .day, value: -7, to: thisWeek)!
            let weeksForward = includeCurrent ? 1 : 0
            let end = cal.date(byAdding: .day, value: 6 + weeksForward * 7, to: start)!
            return (max(allTime.0, start), end)
        default:
            // Unknown/newer range names degrade to All time rather than
            // blanking the widget.
            return allTime
        }
    }

    /// Upstream getSpecificRange for Month type: start = first of the month
    /// `offset` months before today; end = end of month `add` months after
    /// the start.
    private static func monthsBack(_ offset: Int, add: Int, today: Date, earliest: Date) -> (Date, Date) {
        let startMonth = cal.date(byAdding: .month, value: -offset,
                                  to: monthStart(of: today))!
        let endMonthStart = cal.date(byAdding: .month, value: add, to: startMonth)!
        let end = cal.date(byAdding: .day, value: -1,
                           to: cal.date(byAdding: .month, value: 1, to: endMonthStart)!)!
        return (max(earliest, startMonth), end)
    }

    private static func monthStart(of date: Date) -> Date {
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: DateComponents(year: comps.year, month: comps.month, day: 1))!
    }

    /// First day of the week containing `date`, with 0 = Sunday … 6 = Saturday.
    static func weekStart(of date: Date, firstDayOfWeekIdx: Int) -> Date {
        let weekday = cal.component(.weekday, from: date) - 1  // 0-based Sunday
        let idx = (0...6).contains(firstDayOfWeekIdx) ? firstDayOfWeekIdx : 0
        let delta = (weekday - idx + 7) % 7
        return cal.date(byAdding: .day, value: -delta, to: cal.startOfDay(for: date))!
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let isoMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Parse a range start. YYYY-MM snaps to first-of-month, YYYY-MM-DD is used as-is.
    private static func parseRangeStart(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = isoFormatter.date(from: s) { return d }
        if let d = isoMonthFormatter.date(from: s) { return d }  // already first-of-month
        return nil
    }

    /// Parse a range end. YYYY-MM expands to end-of-month so the range is
    /// inclusive of the entire month, matching upstream behavior. YYYY-MM-DD
    /// is used as-is.
    private static func parseRangeEnd(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = isoFormatter.date(from: s) { return d }
        if let d = isoMonthFormatter.date(from: s) {
            let nextMonth = cal.date(byAdding: .month, value: 1, to: d)!
            return cal.date(byAdding: .day, value: -1, to: nextMonth)!
        }
        return nil
    }
}
