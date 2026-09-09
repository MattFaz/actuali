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

    /// The statement closing date whose payment is next due.
    /// Walks back through closed statements rather than assuming only the most
    /// recent one is pending, in case offset exceeds a monthly cycle.
    func upcomingStatementDate(for today: DayDate = .today()) -> DayDate {
        var pendingStatement = cycleRange(for: today).end
        var statement = previousStatementDate(for: today)
        for _ in 0...(dueOffsetDays / 28 + 1) {
            let statementDue = dueDate(forStatement: statement)
            guard today <= statementDue else { break }
            pendingStatement = statement
            statement = previousStatementDate(for: statement)
        }
        return pendingStatement
    }

    /// Next upcoming payment due date.
    func upcomingDueDate(for today: DayDate = .today()) -> DayDate {
        dueDate(forStatement: upcomingStatementDate(for: today))
    }

    /// The last `count` closed billing statement cycles, ordered newest to oldest.
    /// Each item contains the statement's cycle start, cycle end (closing date), and payment due date.
    func recentStatementCycles(count: Int = 3, today: DayDate = .today()) -> [(start: DayDate, end: DayDate, dueDate: DayDate)] {
        guard count > 0 else { return [] }
        var cycles: [(start: DayDate, end: DayDate, dueDate: DayDate)] = []
        var currentEnd = previousStatementDate(for: today)
        for _ in 0..<count {
            let prevEnd = previousStatementDate(for: currentEnd)
            let start = prevEnd.adding(days: 1)
            let due = dueDate(forStatement: currentEnd)
            cycles.append((start: start, end: currentEnd, dueDate: due))
            currentEnd = prevEnd
        }
        return cycles
    }

    /// Status of the payment due for a credit card statement.
    struct StatementDue: Equatable, Hashable, Sendable {
        /// Balance in cents owed when the statement closed (positive).
        let statementBalance: Int
        /// Payments/credits in cents received since the statement closed (positive).
        let paymentsSince: Int
        /// Remaining balance in cents to pay for this statement (positive).
        let remainingDue: Int

        /// Whether this statement has been fully paid off.
        var isPaid: Bool { remainingDue == 0 && statementBalance > 0 }
    }

    /// Record of a closed credit card billing statement with spend, due, and transaction metrics.
    struct StatementRecord: Identifiable, Equatable, Hashable, Sendable {
        var id: Int { statementDate.yyyymmdd }
        let startDate: DayDate
        let endDate: DayDate
        let statementDate: DayDate
        let dueDate: DayDate
        /// Balance in cents owed when the statement closed (positive).
        let statementBalance: Int
        /// Payments/credits in cents received since the statement closed (positive).
        let paymentsSince: Int
        /// Remaining balance in cents to pay for this statement (positive).
        let remainingDue: Int
        /// Outflow spend in cents during the billing cycle (positive).
        let totalSpend: Int
        /// Number of transactions recorded during the billing cycle.
        let transactionCount: Int

        /// Whether this statement has been fully paid off.
        var isPaid: Bool { remainingDue == 0 && statementBalance > 0 }
    }

    /// Computes the statement payment status given raw balances and payments.
    static func calculateStatementDue(
        statementRawBalance: Int,
        paymentsSince: Int,
        liveBalance: Int
    ) -> StatementDue {
        let statementOwed = max(0, -statementRawBalance)
        let unpaid = max(0, statementOwed - paymentsSince)
        let remaining = min(unpaid, max(0, -liveBalance))
        return StatementDue(
            statementBalance: statementOwed,
            paymentsSince: paymentsSince,
            remainingDue: remaining
        )
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
