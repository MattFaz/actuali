import Foundation

/// Billing cycle and statement date logic for credit card accounts.
/// Stored per-budget in UserDefaults (lazy / lightweight: `[accountId: statementDay]`).
/// Due date is assumed to be 15 days after the statement closing date.
struct CreditCardCycle: Equatable, Hashable {
    /// Day of the month the statement closes (1...31).
    let statementDay: Int

    /// Fixed due date offset: 15 days after statement closing.
    /// ponytail: fixed 15-day offset simplifies UI and storage; upgrade path is per-card due offset.
    static let dueDayOffset = 15

    /// Clamps statement day to the given month's actual length.
    private func clampedDay(year: Int, month: Int) -> Int {
        min(statementDay, DayDate.lastDay(year: year, month: month))
    }

    /// The active billing cycle date range containing `today`.
    /// E.g., if statementDay = 15 and today is Feb 20, 2026:
    /// Start: Feb 16, 2026 (day after Feb 15 statement)
    /// End: Mar 15, 2026 (next statement closing date)
    /// E.g., if statementDay = 15 and today is Feb 10, 2026:
    /// Start: Jan 16, 2026
    /// End: Feb 15, 2026
    func cycleRange(for today: DayDate = .today()) -> (start: DayDate, end: DayDate) {
        let currentMonthCloseDay = clampedDay(year: today.year, month: today.month)
        if today.day > currentMonthCloseDay {
            // Cycle closes next month
            let start = DayDate(year: today.year, month: today.month, day: currentMonthCloseDay).adding(days: 1)
            let nextMonth = today.adding(months: 1)
            let endDay = clampedDay(year: nextMonth.year, month: nextMonth.month)
            let end = DayDate(year: nextMonth.year, month: nextMonth.month, day: endDay)
            return (start, end)
        } else {
            // Cycle closes this month
            let prevMonth = today.adding(months: -1)
            let prevCloseDay = clampedDay(year: prevMonth.year, month: prevMonth.month)
            let start = DayDate(year: prevMonth.year, month: prevMonth.month, day: prevCloseDay).adding(days: 1)
            let end = DayDate(year: today.year, month: today.month, day: currentMonthCloseDay)
            return (start, end)
        }
    }

    /// The statement that closed before the active cycle started.
    func previousStatementDate(for today: DayDate = .today()) -> DayDate {
        cycleRange(for: today).start.adding(days: -1)
    }

    /// Next upcoming payment due date.
    /// If the bill for the most recent statement (statementDate + 15 days) hasn't passed yet,
    /// returns that due date. Otherwise, returns the due date for the upcoming cycle.
    func upcomingDueDate(for today: DayDate = .today()) -> DayDate {
        let prevStatement = previousStatementDate(for: today)
        let prevDue = prevStatement.adding(days: Self.dueDayOffset)
        if today <= prevDue {
            return prevDue
        }
        let currentCycleEnd = cycleRange(for: today).end
        return currentCycleEnd.adding(days: Self.dueDayOffset)
    }

    /// Days remaining until the current billing cycle closes.
    func daysRemainingInCycle(for today: DayDate = .today()) -> Int {
        let (_, end) = cycleRange(for: today)
        return max(0, today.days(until: end))
    }

    /// Days remaining until the next payment due date.
    func daysUntilDue(for today: DayDate = .today()) -> Int {
        let due = upcomingDueDate(for: today)
        return max(0, today.days(until: due))
    }
}
