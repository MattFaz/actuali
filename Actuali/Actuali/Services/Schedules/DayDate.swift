import Foundation

/// A timezone-free calendar day. All schedule math happens on these.
struct DayDate: Comparable, Hashable {
    let year: Int, month: Int, day: Int

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }

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

    var yyyymmdd: Int { year * 10000 + month * 100 + day }
    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    static func < (a: DayDate, b: DayDate) -> Bool { a.yyyymmdd < b.yyyymmdd }

    static func lastDay(year: Int, month: Int) -> Int {
        let date = utcCalendar.date(from: DateComponents(year: year, month: month, day: 1))!
        return utcCalendar.range(of: .day, in: .month, for: date)!.count
    }

    private var utcDate: Date {
        DayDate.utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func adding(days: Int) -> DayDate {
        let d = DayDate.utcCalendar.date(byAdding: .day, value: days, to: utcDate)!
        let c = DayDate.utcCalendar.dateComponents([.year, .month, .day], from: d)
        return DayDate(year: c.year!, month: c.month!, day: c.day!)
    }

    /// 1 = Sunday ... 7 = Saturday.
    var weekday: Int { DayDate.utcCalendar.component(.weekday, from: utcDate) }
    var isWeekend: Bool { weekday == 1 || weekday == 7 }

    /// Today in the user's local calendar — the only place local time enters.
    static func today(calendar: Calendar = .current, now: Date = Date()) -> DayDate {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return DayDate(year: c.year!, month: c.month!, day: c.day!)
    }
}
