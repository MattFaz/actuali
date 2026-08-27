import Foundation

/// String month/date arithmetic mirroring loot-core `shared/months.ts` as the
/// goal-template engine uses it. Upstream mixes "yyyy-MM" months and
/// "yyyy-MM-dd" days and compares them lexicographically; these helpers keep
/// those exact semantics (including `addMonths` collapsing a day string to a
/// month string) so ported engine code behaves identically.
enum BudgetMonthMath {

    /// JS `Math.round`: half rounds toward +∞ (matters for negatives).
    static func jsRound(_ value: Double) -> Int {
        Int((value + 0.5).rounded(.down))
    }

    /// Whole currency units → cents, upstream `amountToInteger(x, 2)`.
    static func amountToInteger(_ amount: Double) -> Int {
        jsRound(amount * 100)
    }

    static func yearAndMonth(_ value: String) -> (year: Int, month: Int)? {
        let parts = value.split(separator: "-")
        guard parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]),
              (1...12).contains(month) else { return nil }
        return (year, month)
    }

    /// "2026-08" or "2026-08-15" → 202608; 0 when malformed.
    static func monthInt(_ value: String) -> Int {
        guard let (year, month) = yearAndMonth(value) else { return 0 }
        return year * 100 + month
    }

    static func monthString(fromInt monthInt: Int) -> String {
        String(format: "%04d-%02d", monthInt / 100, monthInt % 100)
    }

    /// Month-or-day string → "yyyy-MM", like upstream `addMonths`.
    static func addMonths(_ value: String, _ n: Int) -> String {
        guard let (year, month) = yearAndMonth(value) else { return value }
        let total = year * 12 + (month - 1) + n
        return String(format: "%04d-%02d", total / 12, total % 12 + 1)
    }

    static func subMonths(_ value: String, _ n: Int) -> String {
        addMonths(value, -n)
    }

    static func nextMonth(_ value: String) -> String {
        addMonths(value, 1)
    }

    static func prevMonth(_ value: String) -> String {
        addMonths(value, -1)
    }

    static func differenceInCalendarMonths(_ a: String, _ b: String) -> Int {
        guard let first = yearAndMonth(a), let second = yearAndMonth(b) else { return 0 }
        return (first.year * 12 + first.month) - (second.year * 12 + second.month)
    }

    static func firstDayOfMonth(_ value: String) -> String {
        guard let (year, month) = yearAndMonth(value) else { return value }
        return String(format: "%04d-%02d-01", year, month)
    }

    /// Month-or-day string → DayDate (day 1 for months), upstream `_parse`.
    static func day(_ value: String) -> DayDate? {
        if let date = DayDate(iso: value) { return date }
        guard let (year, month) = yearAndMonth(value) else { return nil }
        return DayDate(year: year, month: month, day: 1)
    }

    static func addDays(_ value: String, _ n: Int) -> String {
        guard let date = day(value) else { return value }
        return date.adding(days: n).iso
    }

    static func addWeeks(_ value: String, _ n: Int) -> String {
        addDays(value, 7 * n)
    }

    static func subWeeks(_ value: String, _ n: Int) -> String {
        addDays(value, -7 * n)
    }

    static func subDays(_ value: String, _ n: Int) -> String {
        addDays(value, -n)
    }

    static func differenceInCalendarDays(_ a: String, _ b: String) -> Int {
        guard let first = day(a), let second = day(b) else { return 0 }
        return second.days(until: first)
    }

    /// Days in the month of `value` — upstream's
    /// `differenceInCalendarDays(addMonths(m, 1), m)` for daily limits.
    static func daysInMonth(_ value: String) -> Int {
        guard let (year, month) = yearAndMonth(value) else { return 30 }
        return DayDate.lastDay(year: year, month: month)
    }

    static func currentMonth(_ now: Date = Date()) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: now)
        return String(format: "%04d-%02d", components.year ?? 2000, components.month ?? 1)
    }
}
