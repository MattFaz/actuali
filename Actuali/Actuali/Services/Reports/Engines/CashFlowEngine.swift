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

        let monthKeys = months.map { ymdInt(from: $0, calendar: cal) / 100 }
        var monthlyTotals: [Int: (startYMD: Int, endYMD: Int, income: Int, expense: Int)] = [:]
        for (monthStart, monthKey) in zip(months, monthKeys) {
            guard let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart),
                  let monthEnd = cal.date(byAdding: .day, value: -1, to: nextMonth) else {
                continue
            }
            let startYMD = ymdInt(from: monthStart, calendar: cal)
            let endYMD = ymdInt(from: monthEnd, calendar: cal)
            monthlyTotals[monthKey] = (startYMD, endYMD, 0, 0)
        }

        for tx in filtered {
            let monthKey = tx.date / 100
            guard var totals = monthlyTotals[monthKey],
                  tx.date >= totals.startYMD, tx.date <= totals.endYMD else { continue }
            if tx.amount >= 0 {
                totals.income += tx.amount
            } else {
                totals.expense += -tx.amount
            }
            monthlyTotals[monthKey] = totals
        }

        let points = zip(months, monthKeys).map { monthStart, monthKey -> CashFlowPoint in
            let totals = monthlyTotals[monthKey]
            return CashFlowPoint(periodStart: monthStart,
                                 incomeCents: totals?.income ?? 0,
                                 expenseCents: totals?.expense ?? 0)
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
