import Foundation

struct CashFlowPoint: Equatable {
    let periodStart: Date
    let incomeCents: Int
    let expenseCents: Int // positive value
}

struct CashFlowData: Equatable {
    let points: [CashFlowPoint]
}

enum CashFlowEngine {
    static func compute(
        meta: CashFlowMeta?,
        transactions: [Transaction],
        offBudgetAccountIds: Set<String> = [],
        today: Date,
        monthStartRule: MonthStartRule = .calendarMonth,
        context: ConditionsFilter.Context = .empty
    ) -> CashFlowData {
        let adjusted = TimeFrame.adjustedRange(meta?.timeFrame, asOf: today, rule: monthStartRule)
        let (start, end) = adjusted ?? TimeFrame.resolve(meta?.timeFrame, asOf: today)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let periods = if adjusted != nil {
            monthStartRule.periods(from: start, through: end)
        } else {
            monthsBetween(start: start, end: end, calendar: cal).map { month in
                let next = cal.date(byAdding: .month, value: 1, to: month)!
                return month...cal.date(byAdding: .day, value: -1, to: next)!
            }
        }

        // Match the WebUI's cash flow queries (cash-flow-spreadsheet.tsx):
        // only on-budget accounts, and no transfer legs — a transfer's equal
        // and opposite legs would otherwise inflate both income and expense.
        let filtered = transactions
            .filter { !$0.tombstone }
            .filter { $0.transferAcct == nil }
            .filter { !offBudgetAccountIds.contains($0.accountId) }
            .filter { ConditionsFilter.matches(transaction: $0, conditions: meta?.conditions, op: meta?.conditionsOp, context: context) }

        let points = periods.map { period -> CashFlowPoint in
            let startYMD = ymdInt(from: period.lowerBound, calendar: cal)
            let endYMD = ymdInt(from: period.upperBound, calendar: cal)

            var income = 0
            var expense = 0
            for tx in filtered where tx.date >= startYMD && tx.date <= endYMD {
                if tx.amount >= 0 {
                    income += tx.amount
                } else {
                    expense += -tx.amount
                }
            }
            return CashFlowPoint(periodStart: period.lowerBound, incomeCents: income, expenseCents: expense)
        }

        return CashFlowData(points: points)
    }

    private static func monthsBetween(start: Date, end: Date, calendar: Calendar) -> [Date] {
        let startComps = calendar.dateComponents([.year, .month], from: start)
        guard var cursor = calendar.date(from: DateComponents(
            year: startComps.year, month: startComps.month, day: 1
        )) else { return [] }
        var months: [Date] = []
        while cursor <= end {
            months.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return months
    }

    private static func ymdInt(from date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }
}
