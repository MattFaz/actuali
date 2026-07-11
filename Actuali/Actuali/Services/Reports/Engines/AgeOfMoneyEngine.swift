import Foundation

struct AgeOfMoneyData: Equatable {
    struct Point: Equatable {
        var monthLabel: String   // "Jan 2026"
        var age: Int             // days
    }
    enum Trend: Equatable { case up, down, stable }

    var currentAge: Int?         // nil when no expenses in range
    var points: [Point]
    var trend: Trend
    var insufficientData: Bool   // expenses exceeded income buckets

    static let empty = AgeOfMoneyData(currentAge: nil, points: [], trend: .stable,
                                      insufficientData: false)
}

/// Port of the webapp's age-of-money-spreadsheet.ts. Income transactions
/// become FIFO buckets; each expense drains the oldest buckets and its age is
/// the day distance to the last bucket it touched. The headline is the
/// rounded average of the last 10 ages inside the display range; the graph is
/// a per-month cumulative rolling average of the same window.
enum AgeOfMoneyEngine {

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func compute(
        meta: AgeOfMoneyMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context
    ) -> AgeOfMoneyData {
        let (start, resolvedEnd) = TimeFrame.resolve(meta?.timeFrame, asOf: today)
        // Upstream: fixedEnd = min(lastDayOfMonth(end), today). Only the
        // transaction query is clamped to today — the monthly graph still
        // runs through the resolved end month (current month stays visible).
        let fixedEnd = min(resolvedEnd, today)
        let fixedEndYMD = ymdInt(from: fixedEnd)

        // FIFO needs FULL history up to the end date: on-budget accounts only,
        // and no on-budget↔on-budget transfers (they just move the pool
        // around). Transfers to/from off-budget accounts count as real
        // spending/income (upstream's $or on payee.transfer_acct).
        let pool = transactions
            .filter { tx in
                !tx.tombstone
                    && tx.date <= fixedEndYMD
                    && !context.offBudgetAccountIds.contains(tx.accountId)
                    && (tx.transferAcct == nil
                        || context.offBudgetAccountIds.contains(tx.transferAcct!))
                    && ConditionsFilter.matches(transaction: tx,
                                                conditions: meta?.conditions,
                                                op: meta?.conditionsOp,
                                                context: context)
            }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                return (lhs.sortOrder ?? 0, lhs.id) < (rhs.sortOrder ?? 0, rhs.id)
            }

        // FIFO drain (upstream calculateAgeOfMoney).
        struct Bucket { let date: Int; var remaining: Int }
        var buckets: [Bucket] = pool.filter { $0.amount > 0 }
            .map { Bucket(date: $0.date, remaining: $0.amount) }
        var bucketIdx = 0
        var insufficientData = false
        var ages: [(date: Int, age: Int)] = []

        for expense in pool where expense.amount < 0 {
            var remaining = -expense.amount
            var lastBucketDate: Int?
            while remaining > 0 && bucketIdx < buckets.count {
                if buckets[bucketIdx].remaining > 0 {
                    let deduction = min(buckets[bucketIdx].remaining, remaining)
                    buckets[bucketIdx].remaining -= deduction
                    remaining -= deduction
                    lastBucketDate = buckets[bucketIdx].date
                }
                if buckets[bucketIdx].remaining <= 0 { bucketIdx += 1 }
            }
            if remaining > 0 { insufficientData = true }
            if let lastBucketDate {
                let days = daysBetween(lastBucketDate, expense.date)
                ages.append((date: expense.date, age: max(0, days)))
            }
        }

        // Only ages inside the display range count toward headline and graph.
        let displayStartYMD = ymdInt(from: monthStart(of: start))
        let displayAges = ages.filter { $0.date >= displayStartYMD }

        // Headline (upstream calculateAverageAge, count = 10).
        let currentAge: Int? = displayAges.isEmpty ? nil : {
            let lastTen = displayAges.suffix(10).map(\.age)
            return Int((Double(lastTen.reduce(0, +)) / Double(lastTen.count)).rounded())
        }()

        // Per-month cumulative rolling average (upstream calculateGraphData,
        // monthly granularity). Months with a running window but no new ages
        // still emit a point (the average carries forward).
        var points: [AgeOfMoneyData.Point] = []
        var agesSoFar: [Int] = []
        var month = monthStart(of: start)
        let lastMonth = monthStart(of: resolvedEnd)
        while month <= lastMonth {
            let monthKey = ymdInt(from: month) / 100  // YYYYMM
            agesSoFar.append(contentsOf: displayAges.filter { $0.date / 100 == monthKey }.map(\.age))
            if !agesSoFar.isEmpty {
                let lastTen = agesSoFar.suffix(10)
                let avg = Int((Double(lastTen.reduce(0, +)) / Double(lastTen.count)).rounded())
                points.append(.init(monthLabel: labelFormatter.string(from: month), age: avg))
            }
            guard let next = cal.date(byAdding: .month, value: 1, to: month) else { break }
            month = next
        }

        // Trend: last two points, ±2 day threshold (upstream calculateTrend).
        let trend: AgeOfMoneyData.Trend
        if points.count < 2 {
            trend = .stable
        } else {
            let diff = points[points.count - 1].age - points[points.count - 2].age
            trend = diff > 2 ? .up : (diff < -2 ? .down : .stable)
        }

        return AgeOfMoneyData(currentAge: currentAge, points: points,
                              trend: trend, insufficientData: insufficientData)
    }

    private static let labelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM yyyy"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func monthStart(of date: Date) -> Date {
        let c = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: DateComponents(year: c.year, month: c.month, day: 1)) ?? date
    }

    private static func ymdInt(from date: Date) -> Int {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    private static func daysBetween(_ from: Int, _ to: Int) -> Int {
        // NOT Transaction.date(fromYYYYMMDD:) — that uses Calendar.current
        // and would shift days across timezones. Stay in UTC.
        guard let f = cal.date(from: DateComponents(year: from / 10000,
                                                    month: (from % 10000) / 100,
                                                    day: from % 100)),
              let t = cal.date(from: DateComponents(year: to / 10000,
                                                    month: (to % 10000) / 100,
                                                    day: to % 100)) else { return 0 }
        return cal.dateComponents([.day], from: f, to: t).day ?? 0
    }
}
