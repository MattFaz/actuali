import Foundation

/// A schedule's lifecycle state, mirroring loot-core `getStatus`.
enum ScheduleStatus: String, Hashable, CaseIterable {
    case completed
    case paid
    case due
    case upcoming
    case missed
    case scheduled
}

/// How long the "upcoming" window is, mirroring loot-core `getUpcomingDays`.
///
/// The stored value is a string because upstream overloads it: a bare number is
/// a literal day count, `currentMonth`/`oneMonth` are named windows, and
/// `N-day|week|month|year` is a compound form. A schedule's own
/// `custom_upcoming_length` overrides the budget-wide preference.
enum ScheduleUpcomingLength {
    /// Upstream's default when no preference is set.
    static let fallback = "7"

    static func days(for raw: String?, today: DayDate = .today()) -> Int {
        let value = raw.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        // Upstream measures the month-based windows from the FIRST of the
        // current month, not from `today` (it passes a "YYYY-MM" month string
        // into a day-difference helper). Reproduced deliberately so the badge
        // in Actuali and the badge on the web agree.
        let monthStart = DayDate(year: today.year, month: today.month, day: 1)

        switch value {
        case "currentMonth":
            return DayDate.lastDay(year: today.year, month: today.month) - today.day
        case "oneMonth":
            return monthStart.days(until: monthStart.adding(months: 1))
        default:
            guard value.contains("-") else {
                // Upstream returns NaN for unparseable input, which silently
                // makes every comparison false. Fall back to the default
                // window instead — a wrong badge beats an unreadable one.
                return Int(value) ?? 7
            }
            let parts = value.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let parsed = Int(parts[0]) else { return 7 }
            let amount = max(1, parsed)
            switch parts[1] {
            case "day":   return amount
            case "week":  return amount * 7
            case "month": return monthStart.days(until: today.adding(months: amount)) + 1
            case "year":  return monthStart.days(until: today.adding(months: amount * 12)) + 1
            default:      return 7
            }
        }
    }
}

enum ScheduleStatusCalculator {
    /// Port of loot-core `getStatus`. The branch ORDER is the contract:
    /// completed wins over paid, paid wins over any date comparison.
    static func status(
        nextDate: DayDate?,
        completed: Bool,
        hasTransaction: Bool,
        upcomingLength: String?,
        today: DayDate = .today()
    ) -> ScheduleStatus {
        if completed { return .completed }
        if hasTransaction { return .paid }
        // A schedule whose next-date row is missing or unreadable still has to
        // render; upstream can't reach this case because its view guarantees
        // the column.
        guard let nextDate else { return .scheduled }

        if nextDate == today { return .due }
        let window = today.adding(days: days(upcomingLength, today))
        if nextDate > today, nextDate <= window { return .upcoming }
        if nextDate < today { return .missed }
        return .scheduled
    }

    /// Port of loot-core `getScheduleOccurrenceMatchStartDate`: the earliest
    /// date a transaction may carry and still count as covering this
    /// occurrence.
    ///
    /// An exact-date schedule and an auto-posting one both match only on or
    /// after the occurrence itself — a lookback there would let yesterday's
    /// posting satisfy today's occurrence. Everything else (a manual
    /// `isapprox` schedule) allows two days, so paying a bill early still
    /// reads as `paid`.
    static func occurrenceMatchStartDate(
        nextDate: DayDate,
        dateOp: String?,
        postsTransaction: Bool
    ) -> DayDate {
        if dateOp == "is" { return nextDate }
        if postsTransaction { return nextDate }
        return nextDate.adding(days: -2)
    }

    private static func days(_ upcomingLength: String?, _ today: DayDate) -> Int {
        ScheduleUpcomingLength.days(for: upcomingLength, today: today)
    }
}
