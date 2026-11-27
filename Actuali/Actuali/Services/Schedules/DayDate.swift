import Foundation

/// A timezone-free calendar day. All schedule math happens on these.
struct DayDate: Comparable, Hashable {
    let year: Int, month: Int, day: Int

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    init?(yyyymmdd: Int) {
        let y = yyyymmdd / 10000, m = (yyyymmdd / 100) % 100, d = yyyymmdd % 100
        guard (1...12).contains(m), d >= 1, d <= DayDate.lastDay(year: y, month: m) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// Accepts "YYYY-MM-DD" or longer ISO strings (first 10 chars used).
    init?(iso: String) {
        let s = String(iso.prefix(10))
        let parts = s.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= DayDate.lastDay(year: y, month: m) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    var yyyymmdd: Int {
        year * 10000 + month * 100 + day
    }

    var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func < (a: DayDate, b: DayDate) -> Bool {
        a.yyyymmdd < b.yyyymmdd
    }

    static func lastDay(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11:
            30
        default:
            31
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    }

    /// This calendar day as a `Date`, pinned to midday UTC so a timezone shift
    /// can't slide it into the neighbouring day. Exposed for Swift Charts,
    /// whose axes plot `Date` — the schedule math all stays on `DayDate`.
    var utcDate: Date {
        DayDate.utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// "Sep 26, 2026" in the user's locale. Formatted in UTC to match
    /// `utcDate`, so the day shown is the day stored in any timezone.
    var displayText: String {
        utcDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }

    /// Gregorian day number relative to 1970-01-01. Integer-only so schedule
    /// calculations can use it inside contribution and compounding loops.
    var dayNumber: Int {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    func adding(days: Int) -> DayDate {
        let shiftedDay = dayNumber + days + 719_468
        let era = (shiftedDay >= 0 ? shiftedDay : shiftedDay - 146_096) / 146_097
        let dayOfEra = shiftedDay - era * 146_097
        let yearOfEra = (
            dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096
        ) / 365
        var year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        year += month <= 2 ? 1 : 0
        return DayDate(year: year, month: month, day: day)
    }

    /// 1 = Sunday ... 7 = Saturday.
    var weekday: Int {
        DayDate.utcCalendar.component(.weekday, from: utcDate)
    }

    var isWeekend: Bool {
        weekday == 1 || weekday == 7
    }

    /// Today in the user's local calendar — the only place local time enters.
    static func today(calendar: Calendar = .current, now: Date = Date()) -> DayDate {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return DayDate(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Whole calendar days from this day to `other`; negative when `other`
    /// is earlier. Integer day numbers avoid timezone and DST conversions.
    func days(until other: DayDate) -> Int {
        other.dayNumber - dayNumber
    }

    /// Shifted by whole months, clamped to the target month's length
    /// (Jan 31 + 1 month = Feb 28), matching date-fns `addMonths` — which is
    /// what upstream's upcoming-window math is built on.
    func adding(months: Int) -> DayDate {
        let total = year * 12 + (month - 1) + months
        // Swift integer division truncates toward zero; floor it so a negative
        // shift doesn't land a month late.
        let y = total >= 0 ? total / 12 : (total - 11) / 12
        let m = total - y * 12 + 1
        return DayDate(year: y, month: m, day: min(day, DayDate.lastDay(year: y, month: m)))
    }
}
