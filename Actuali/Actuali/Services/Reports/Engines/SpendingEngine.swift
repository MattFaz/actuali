import Foundation

struct SpendingData: Equatable {
    let currentSpentCents: Int    // positive
    let comparisonCents: Int      // positive
}

enum SpendingEngine {

    static func compute(
        meta: SpendingMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context = .empty
    ) -> SpendingData {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let monthComponents = cal.dateComponents([.year, .month], from: today)
        guard let monthStart = cal.date(from: DateComponents(
            year: monthComponents.year, month: monthComponents.month, day: 1
        )) else { return SpendingData(currentSpentCents: 0, comparisonCents: 0) }

        let filtered = transactions
            .filter { !$0.tombstone }
            .filter { ConditionsFilter.matches(transaction: $0, conditions: meta?.conditions, op: meta?.conditionsOp, context: context) }

        let current = monthSpending(transactions: filtered, monthStart: monthStart, calendar: cal)

        let todayDay = cal.component(.day, from: today)

        let comparison: Int
        switch meta?.mode {
        case .singleMonth?:
            if let compareTo = meta?.compareTo,
               let compareMonth = parseMonthStart(from: compareTo, calendar: cal) {
                comparison = monthSpending(transactions: filtered, monthStart: compareMonth, calendar: cal)
            } else {
                comparison = averageOfPriorMonths(transactions: filtered,
                                                  currentMonthStart: monthStart,
                                                  count: 3,
                                                  throughDay: todayDay,
                                                  calendar: cal)
            }
        case .budget?:
            comparison = 0
        case .average?, .none:
            comparison = averageOfPriorMonths(transactions: filtered,
                                              currentMonthStart: monthStart,
                                              count: 3,
                                              throughDay: todayDay,
                                              calendar: cal)
        }

        return SpendingData(currentSpentCents: current, comparisonCents: comparison)
    }

    private static func monthSpending(
        transactions: [Transaction],
        monthStart: Date,
        calendar: Calendar,
        throughDay: Int? = nil
    ) -> Int {
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
              let monthEnd = calendar.date(byAdding: .day, value: -1, to: nextMonth) else { return 0 }
        let lastDay = calendar.component(.day, from: monthEnd)
        let endDay = throughDay.map { min($0, lastDay) } ?? lastDay
        guard let cutoff = calendar.date(byAdding: .day, value: endDay - 1, to: monthStart) else { return 0 }
        let startYMD = ymdInt(from: monthStart, calendar: calendar)
        let endYMD = ymdInt(from: cutoff, calendar: calendar)
        let totalNegative = transactions
            .filter { $0.date >= startYMD && $0.date <= endYMD && $0.amount < 0 }
            .reduce(0) { $0 + $1.amount }
        return -totalNegative
    }

    private static func averageOfPriorMonths(
        transactions: [Transaction],
        currentMonthStart: Date,
        count: Int,
        throughDay: Int?,
        calendar: Calendar
    ) -> Int {
        // Matches WebUI behavior: average cumulative spending through `throughDay`
        // across the `count` prior months. When throughDay >= 28, the WebUI buckets
        // days 28+ together and uses full-month totals for prior months — we pass
        // nil to monthSpending in that case.
        let dayParam: Int? = (throughDay ?? 0) >= 28 ? nil : throughDay
        var sum = 0
        for i in 1...count {
            guard let priorStart = calendar.date(byAdding: .month, value: -i, to: currentMonthStart) else { continue }
            sum += monthSpending(transactions: transactions,
                                 monthStart: priorStart,
                                 calendar: calendar,
                                 throughDay: dayParam)
        }
        return sum / count
    }

    private static func parseMonthStart(from string: String, calendar: Calendar) -> Date? {
        // Accept "YYYY-MM" or "YYYY-MM-DD"
        let isoMonth = DateFormatter()
        isoMonth.dateFormat = "yyyy-MM"
        isoMonth.timeZone = TimeZone(identifier: "UTC")
        if let d = isoMonth.date(from: string) { return d }
        let isoDay = DateFormatter()
        isoDay.dateFormat = "yyyy-MM-dd"
        isoDay.timeZone = TimeZone(identifier: "UTC")
        if let d = isoDay.date(from: string) {
            return calendar.date(from: calendar.dateComponents([.year, .month], from: d))
        }
        return nil
    }

    private static func ymdInt(from date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }
}
