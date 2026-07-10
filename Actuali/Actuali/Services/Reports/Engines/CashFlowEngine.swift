import Foundation

struct CashFlowPoint: Equatable {
    let periodStart: Date
    let incomeCents: Int
    let expenseCents: Int  // positive value
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
        context: ConditionsFilter.Context = .empty
    ) -> CashFlowData {
        let (start, end) = TimeFrame.resolve(meta?.timeFrame, asOf: today)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let months = monthsBetween(start: start, end: end, calendar: cal)

        // Match the WebUI's cash flow queries (cash-flow-spreadsheet.tsx):
        // only on-budget accounts, and no transfer legs — a transfer's equal
        // and opposite legs would otherwise inflate both income and expense.
        let filtered = transactions
            .filter { !$0.tombstone }
            .filter { $0.transferAcct == nil }
            .filter { !offBudgetAccountIds.contains($0.accountId) }
            .filter { ConditionsFilter.matches(transaction: $0, conditions: meta?.conditions, op: meta?.conditionsOp, context: context) }

        let points = months.map { monthStart -> CashFlowPoint in
            guard let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart),
                  let monthEnd = cal.date(byAdding: .day, value: -1, to: nextMonth) else {
                return CashFlowPoint(periodStart: monthStart, incomeCents: 0, expenseCents: 0)
            }
            let startYMD = ymdInt(from: monthStart, calendar: cal)
            let endYMD = ymdInt(from: monthEnd, calendar: cal)

            var income = 0
            var expense = 0
            for tx in filtered where tx.date >= startYMD && tx.date <= endYMD {
                if tx.amount >= 0 { income += tx.amount }
                else { expense += -tx.amount }
            }
            return CashFlowPoint(periodStart: monthStart, incomeCents: income, expenseCents: expense)
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
