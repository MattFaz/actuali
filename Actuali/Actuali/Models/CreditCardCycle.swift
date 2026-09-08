import Foundation

/// Billing cycle and statement date logic for credit card accounts.
/// Stored per-budget in UserDefaults (lazy / lightweight: `[accountId: statementDay]`
/// plus `[accountId: dueOffsetDays]`).
struct CreditCardCycle: Equatable, Hashable {
    /// Day of the month the statement closes (1...31).
    let statementDay: Int

    /// Days between the statement closing and the payment due date. The
    /// interest-free period is set by the issuer, not the network — US cards
    /// cluster around 21-25 days while Australian ones commonly run 25 or 45 —
    /// so it is configured per card rather than assumed.
    let dueOffsetDays: Int

    /// Applied to cards configured before the offset became per-card.
    static let defaultDueOffsetDays = 15

    /// Widest offset the picker offers; also bounds the pending-statement walk
    /// in `upcomingDueDate`.
    static let maxDueOffsetDays = 60

    init(statementDay: Int, dueOffsetDays: Int = Self.defaultDueOffsetDays) {
        self.statementDay = statementDay
        self.dueOffsetDays = dueOffsetDays
    }

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
    ///
    /// Statements close monthly but the due offset can run longer than a cycle
    /// (45+ days is common outside the US), so more than one closed statement
    /// can be awaiting payment at once. The next payment is the earliest one
    /// whose due date hasn't passed, so this walks back through closed
    /// statements rather than assuming only the most recent one is pending.
    func upcomingDueDate(for today: DayDate = .today()) -> DayDate {
        // Fallback: everything already closed is paid or past due, so the next
        // payment covers the cycle now running.
        var due = cycleRange(for: today).end.adding(days: dueOffsetDays)
        var statement = previousStatementDate(for: today)
        // A statement can only be pending while its due date is within
        // `dueOffsetDays` of today, which spans at most one cycle per whole
        // month of offset — the extra step is the one that ends the walk.
        for _ in 0...(dueOffsetDays / 28 + 1) {
            let statementDue = statement.adding(days: dueOffsetDays)
            guard today <= statementDue else { break }
            due = statementDue
            statement = previousStatementDate(for: statement)
        }
        return due
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

    /// One-line payment summary ("Due 30 Aug 2026 (9d)"). Shared by the Credit
    /// Cards row and the account detail header so the two can't word the same
    /// fact differently.
    func dueSummary(for today: DayDate = .today()) -> String {
        let days = daysUntilDue(for: today)
        if days == 0 { return String(localized: "Due today") }
        if days == 1 { return String(localized: "Due tomorrow") }
        let dueStr = Transaction.formattedDate(from: upcomingDueDate(for: today).yyyymmdd, style: .abbreviated)
        return String(format: String(localized: "Due %@ (%lldd)"), dueStr, Int64(days))
    }

    /// Compact variant of `dueSummary` for pill badges ("Due in 27d"). Defers to
    /// `dueSummary` within a day of the due date, so the two can't drift on the
    /// wording that matters most.
    func dueShortSummary(for today: DayDate = .today()) -> String {
        let days = daysUntilDue(for: today)
        return days <= 1 ? dueSummary(for: today) : String(format: String(localized: "Due in %lldd"), Int64(days))
    }
}
