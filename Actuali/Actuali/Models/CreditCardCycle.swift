import Foundation

/// Billing cycle and statement date logic for credit card accounts.
/// Stored per-budget in UserDefaults (lazy / lightweight: `[accountId: statementDay]`
/// plus `[accountId: dueOffsetDays]`).
struct CreditCardCycle: Equatable, Hashable {
    /// How the payment due date is calculated: either relative to statement closing,
    /// or a fixed calendar day of the month.
    enum PaymentDue: Equatable, Hashable, Sendable {
        case daysAfter(Int)
        case dayOfMonth(Int)
    }

    /// Day of the month the statement closes (1...31).
    let statementDay: Int

    /// Payment due rule for this card.
    let paymentDue: PaymentDue

    /// Days between statement closing and payment due date when using relative offset,
    /// or `defaultDueOffsetDays` when using a fixed day of the month.
    var dueOffsetDays: Int {
        switch paymentDue {
        case .daysAfter(let days): return days
        case .dayOfMonth: return Self.defaultDueOffsetDays
        }
    }

    /// Applied to cards configured before the offset became per-card.
    static let defaultDueOffsetDays = 15

    /// Widest offset the picker offers; also bounds the pending-statement walk
    /// in `upcomingDueDate`.
    static let maxDueOffsetDays = 60

    init(statementDay: Int, paymentDue: PaymentDue = .daysAfter(Self.defaultDueOffsetDays)) {
        self.statementDay = statementDay
        self.paymentDue = paymentDue
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

    /// Calculates the payment due date corresponding to a given statement closing date.
    func dueDate(forStatement statement: DayDate) -> DayDate {
        switch paymentDue {
        case .daysAfter(let days):
            return statement.adding(days: days)
        case .dayOfMonth(let day):
            // If dueDay > statementDay: payment is due in the same month as statement closing (e.g. 5th -> 25th).
            // If dueDay <= statementDay: payment is due in the following month (e.g. 15th -> 1st).
            let month = (day > statementDay) ? statement : statement.adding(months: 1)
            let clamped = min(day, DayDate.lastDay(year: month.year, month: month.month))
            return DayDate(year: month.year, month: month.month, day: clamped)
        }
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
        var due = dueDate(forStatement: cycleRange(for: today).end)
        var statement = previousStatementDate(for: today)
        // A statement can only be pending while its due date is within the due
        // window of today, which spans at most one cycle per whole month of
        // offset. A fixed day of the month never exceeds one cycle, and the 15
        // this returns for that rule already bounds the walk.
        for _ in 0...(dueOffsetDays / 28 + 1) {
            let statementDue = dueDate(forStatement: statement)
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
        if days == 0 { return "Due today" }
        if days == 1 { return "Due tomorrow" }
        let dueStr = Transaction.formattedDate(from: upcomingDueDate(for: today).yyyymmdd, style: .abbreviated)
        return "Due \(dueStr) (\(days)d)"
    }

    /// Compact variant of `dueSummary` for pill badges ("Due in 27d"). Defers to
    /// `dueSummary` within a day of the due date, so the two can't drift on the
    /// wording that matters most.
    func dueShortSummary(for today: DayDate = .today()) -> String {
        let days = daysUntilDue(for: today)
        return days <= 1 ? dueSummary(for: today) : "Due in \(days)d"
    }
}
