import Foundation

struct NetWorthPoint: Equatable {
    let date: Date
    let balanceCents: Int
}

struct NetWorthData: Equatable {
    let points: [NetWorthPoint]
}

enum NetWorthEngine {

    static func compute(
        meta: NetWorthMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context = .empty
    ) -> NetWorthData {
        let (start, end) = TimeFrame.resolve(meta?.timeFrame, asOf: today)
        let interval = meta?.interval ?? .monthly

        let filtered = transactions
            .filter { !$0.tombstone }
            .filter { ConditionsFilter.matches(transaction: $0, conditions: meta?.conditions, op: meta?.conditionsOp, context: context) }

        let boundaries = intervalBoundaries(from: start, to: end, interval: interval)

        let points = boundaries.map { boundary -> NetWorthPoint in
            let boundaryYMD = ymdInt(from: boundary)
            let balance = filtered
                .filter { $0.date <= boundaryYMD }
                .reduce(0) { $0 + $1.amount }
            return NetWorthPoint(date: boundary, balanceCents: balance)
        }

        return NetWorthData(points: points)
    }

    /// Returns one anchor date per interval. For monthly: the last day of each
    /// month in the range (capped at `end`). For yearly: Dec 31 of each year
    /// (capped at `end`). For weekly: Saturday (calendar end-of-week, capped at
    /// `end`). For daily: each day.
    private static func intervalBoundaries(
        from start: Date,
        to end: Date,
        interval: NetWorthMeta.Interval
    ) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        switch interval {
        case .daily:
            var result: [Date] = []
            var cursor = start
            while cursor <= end {
                result.append(cursor)
                guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            return result

        case .monthly:
            // For each month between start and end, use end-of-month
            // (or `end` if it's in the final month).
            var result: [Date] = []
            let startComps = cal.dateComponents([.year, .month], from: start)
            guard var monthStart = cal.date(from: DateComponents(
                year: startComps.year, month: startComps.month, day: 1
            )) else { return [] }

            while monthStart <= end {
                guard let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart),
                      let monthEnd = cal.date(byAdding: .day, value: -1, to: nextMonth) else { break }
                let pointDate = min(monthEnd, end)
                result.append(pointDate)
                monthStart = nextMonth
            }
            return result

        case .yearly:
            var result: [Date] = []
            var year = cal.component(.year, from: start)
            let endYear = cal.component(.year, from: end)
            while year <= endYear {
                guard let yearEnd = cal.date(from: DateComponents(year: year, month: 12, day: 31)) else { break }
                let pointDate = min(yearEnd, end)
                result.append(pointDate)
                year += 1
            }
            return result

        case .weekly:
            var result: [Date] = []
            var cursor = start
            while cursor <= end {
                // Move to Saturday (end of week with Sunday-first calendar).
                let weekday = cal.component(.weekday, from: cursor)
                let daysToSaturday = (7 - weekday) % 7  // Sun=1 → 6 days to Sat; Sat=7 → 0
                guard let weekEnd = cal.date(byAdding: .day, value: daysToSaturday, to: cursor) else { break }
                let pointDate = min(weekEnd, end)
                result.append(pointDate)
                guard let nextWeek = cal.date(byAdding: .day, value: 7, to: weekEnd) else { break }
                cursor = nextWeek
            }
            return result
        }
    }

    private static func ymdInt(from date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }
}
