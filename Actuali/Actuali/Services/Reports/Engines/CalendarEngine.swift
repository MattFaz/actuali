import Foundation

/// Mirrors upstream `CalendarWidget['meta']` (CalendarCard.tsx).
struct CalendarMeta: Codable, Equatable {
    let name: String?
    let conditions: [WidgetRuleCondition]?
    let conditionsOp: String?
    let timeFrame: WidgetTimeFrame?
}

/// One grid cell. `dayOfMonth` is nil for the leading/trailing padding cells
/// that align the month grid to the configured first weekday.
struct CalendarDayCell: Equatable {
    let dayOfMonth: Int?
    let incomeCents: Int    // absolute value
    let expenseCents: Int   // absolute value
    /// 0–100: this day's share of the month's income/expense total, matching
    /// upstream `getBarLength` (calendar-spreadsheet.ts).
    let incomeSize: Double
    let expenseSize: Double
}

struct CalendarMonthData: Equatable {
    let monthStart: Date
    /// Row-major weeks; count is a multiple of 7 and the first cell falls on
    /// the configured first weekday.
    let days: [CalendarDayCell]
    let totalIncomeCents: Int
    let totalExpenseCents: Int
}

struct CalendarData: Equatable {
    let months: [CalendarMonthData]
    let totalIncomeCents: Int
    let totalExpenseCents: Int
    /// 0 = Sunday … 6 = Saturday, echoed back for the view's weekday header.
    let firstDayOfWeekIdx: Int
}

enum CalendarEngine {

    static func compute(
        meta: CalendarMeta?,
        transactions: [Transaction],
        today: Date,
        firstDayOfWeekIdx: Int,
        context: ConditionsFilter.Context = .empty
    ) -> CalendarData {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        // Upstream expands the resolved range to whole months
        // (firstDayOfMonth(start) .. lastDayOfMonth(end)).
        let (rawStart, rawEnd) = TimeFrame.resolve(meta?.timeFrame, asOf: today)
        let firstMonth = monthStart(of: rawStart, calendar: cal)
        let lastMonth = monthStart(of: rawEnd, calendar: cal)

        let startYMD = ymdInt(from: firstMonth, calendar: cal)
        let endYMD = ymdInt(from: endOfMonth(lastMonth, calendar: cal), calendar: cal)

        let filtered = transactions
            .filter { !$0.tombstone }
            .filter { $0.date >= startYMD && $0.date <= endYMD }
            .filter { ConditionsFilter.matches(transaction: $0, conditions: meta?.conditions, op: meta?.conditionsOp, context: context) }

        // Upstream buckets income (amount > 0) and expenses (amount < 0)
        // separately per day; zero-amount transactions land in neither.
        var incomeByDay: [Int: Int] = [:]   // YYYYMMDD -> cents
        var expenseByDay: [Int: Int] = [:]
        for tx in filtered {
            if tx.amount > 0 {
                incomeByDay[tx.date, default: 0] += tx.amount
            } else if tx.amount < 0 {
                expenseByDay[tx.date, default: 0] += tx.amount
            }
        }

        // Out-of-range values fall back to Sunday, matching upstream.
        let weekStart = (0...6).contains(firstDayOfWeekIdx) ? firstDayOfWeekIdx : 0

        var months: [CalendarMonthData] = []
        var cursor = firstMonth
        while cursor <= lastMonth {
            months.append(monthData(monthStart: cursor,
                                    incomeByDay: incomeByDay,
                                    expenseByDay: expenseByDay,
                                    weekStart: weekStart,
                                    calendar: cal))
            guard let next = cal.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }

        return CalendarData(
            months: months,
            totalIncomeCents: months.reduce(0) { $0 + $1.totalIncomeCents },
            totalExpenseCents: months.reduce(0) { $0 + $1.totalExpenseCents },
            firstDayOfWeekIdx: weekStart
        )
    }

    private static func monthData(
        monthStart: Date,
        incomeByDay: [Int: Int],
        expenseByDay: [Int: Int],
        weekStart: Int,
        calendar: Calendar
    ) -> CalendarMonthData {
        let yyyymm = ymdInt(from: monthStart, calendar: calendar) / 100
        let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30

        var totalIncome = 0
        var totalExpense = 0
        for day in 1...daysInMonth {
            totalIncome += incomeByDay[yyyymm * 100 + day] ?? 0
            totalExpense += abs(expenseByDay[yyyymm * 100 + day] ?? 0)
        }

        // Leading padding back to the configured first weekday, trailing
        // padding to a whole number of weeks (upstream recalculate()).
        let jsWeekday = calendar.component(.weekday, from: monthStart) - 1  // 0 = Sunday
        let leading = (jsWeekday - weekStart + 7) % 7
        var totalCells = leading + daysInMonth
        if totalCells % 7 != 0 { totalCells += 7 - totalCells % 7 }

        let padding = CalendarDayCell(dayOfMonth: nil, incomeCents: 0, expenseCents: 0,
                                      incomeSize: 0, expenseSize: 0)
        var cells: [CalendarDayCell] = []
        for i in 0..<totalCells {
            let day = i - leading + 1
            guard day >= 1 && day <= daysInMonth else {
                cells.append(padding)
                continue
            }
            let income = incomeByDay[yyyymm * 100 + day] ?? 0
            let expense = abs(expenseByDay[yyyymm * 100 + day] ?? 0)
            cells.append(CalendarDayCell(
                dayOfMonth: day,
                incomeCents: income,
                expenseCents: expense,
                incomeSize: totalIncome > 0 ? Double(income) / Double(totalIncome) * 100 : 0,
                expenseSize: totalExpense > 0 ? Double(expense) / Double(totalExpense) * 100 : 0
            ))
        }

        return CalendarMonthData(monthStart: monthStart, days: cells,
                                 totalIncomeCents: totalIncome, totalExpenseCents: totalExpense)
    }

    private static func monthStart(of date: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? date
    }

    private static func endOfMonth(_ monthStartDate: Date, calendar: Calendar) -> Date {
        guard let next = calendar.date(byAdding: .month, value: 1, to: monthStartDate),
              let last = calendar.date(byAdding: .day, value: -1, to: next) else { return monthStartDate }
        return last
    }

    private static func ymdInt(from date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }
}
