import Foundation

/// Mirrors upstream `CrossoverWidget` meta (loot-core dashboard models).
/// `expectedContribution` is monthly cents, like all upstream amounts.
struct CrossoverMeta: Codable, Equatable {
    let name: String?
    let expenseCategoryIds: [String]?
    let incomeAccountIds: [String]?
    let timeFrame: WidgetTimeFrame?
    let safeWithdrawalRate: Double?      // annual, default 0.04
    let estimatedReturn: Double?         // annual, nil = derive from history
    let expectedContribution: Double?    // monthly cents, default 0
    let projectionType: ProjectionType?  // default .hampel
    let showHiddenCategories: Bool?
    let expenseAdjustmentFactor: Double? // default 1.0

    enum ProjectionType: String, Codable {
        case hampel, median, mean
    }
}

struct CrossoverPoint: Equatable {
    let month: Date                       // first of month, UTC
    let investmentIncomeCents: Int        // balance * monthly SWR
    let expensesCents: Int
    let nestEggCents: Int
    let adjustedExpensesCents: Int?       // projection points only
    let isProjection: Bool
}

struct CrossoverData: Equatable {
    let points: [CrossoverPoint]
    let crossoverMonth: Date?             // projected month income first covers adjusted expenses
    let lastKnownBalanceCents: Int
    let lastKnownMonthlyIncomeCents: Int
    let lastKnownMonthlyExpensesCents: Int
    let historicalReturn: Double?         // annualized CAGR of the selected accounts
    let yearsToRetire: Double?
    let targetMonthlyIncomeCents: Int?
    let targetNestEggCents: Int?

    static let empty = CrossoverData(
        points: [], crossoverMonth: nil,
        lastKnownBalanceCents: 0, lastKnownMonthlyIncomeCents: 0,
        lastKnownMonthlyExpensesCents: 0, historicalReturn: nil,
        yearsToRetire: nil, targetMonthlyIncomeCents: nil,
        targetNestEggCents: nil
    )
}

/// Port of upstream crossover-spreadsheet.ts + the date-range resolution in
/// CrossoverCard.tsx, computed over in-memory transactions.
enum CrossoverEngine {

    /// - Parameters:
    ///   - categories: all live categories — used to default the expense set
    ///     to every non-income category and to honor `showHiddenCategories`.
    ///   - accountIds: all live account ids — the default income-account set
    ///     when meta doesn't select specific accounts (upstream `useAccounts`).
    static func compute(
        meta: CrossoverMeta?,
        transactions: [Transaction],
        categories: [Category],
        accountIds: [String],
        today: Date
    ) -> CrossoverData {
        let incomeAccountIds = meta?.incomeAccountIds ?? accountIds
        guard !incomeAccountIds.isEmpty else { return .empty }

        let live = transactions.filter { !$0.tombstone }

        // Date range: months as year*12 + (month-1) indices. Upstream card
        // clamps to [earliest transaction month, previous month] and defaults
        // to mode "full" (Crossover.tsx defaultTimeFrame).
        let currentMonth = monthIndex(of: today)
        let latestMonth = currentMonth - 1
        let earliestMonth = min(
            live.map { monthIndex(ofYMD: $0.date) }.min() ?? latestMonth,
            latestMonth
        )
        func clamp(_ m: Int) -> Int { min(max(m, earliestMonth), latestMonth) }

        let tf = meta?.timeFrame
        var start: Int
        var end: Int
        switch tf?.mode ?? .full {
        case .full:
            start = earliestMonth
            end = latestMonth
        case .slidingWindow:
            // calculateTimeRange keeps the stored window width ending at the
            // current month; the card then shifts both back one month.
            let storedStart = parseMonthIndex(tf?.start) ?? currentMonth - 120
            let storedEnd = parseMonthIndex(tf?.end) ?? currentMonth - 1
            let offset = storedEnd - storedStart
            start = clamp(currentMonth - offset - 1)
            end = clamp(currentMonth - 1)
        case .lastMonth:
            start = clamp(currentMonth - 1)
            end = clamp(currentMonth - 1)
        case .lastYear:
            let priorJan = ((currentMonth / 12) - 1) * 12
            start = clamp(priorJan)
            end = clamp(priorJan + 11)
        case .yearToDate:
            start = clamp((currentMonth / 12) * 12)
            end = clamp(currentMonth)
        case .priorYearToDate:
            start = clamp(((currentMonth / 12) - 1) * 12)
            end = clamp(currentMonth - 12)
        case .static:
            start = clamp(parseMonthIndex(tf?.start) ?? currentMonth - 120)
            end = clamp(parseMonthIndex(tf?.end) ?? currentMonth - 1)
        }
        if end < start { end = start }
        let months = Array(start...end)

        // Expense category set: stored ids, or every non-income category,
        // then filter hidden unless showHiddenCategories.
        let showHidden = meta?.showHiddenCategories ?? false
        let baseCategories: [Category]
        if let storedIds = meta?.expenseCategoryIds {
            let stored = Set(storedIds)
            baseCategories = categories.filter { stored.contains($0.id) }
        } else {
            baseCategories = categories.filter { !$0.isIncome }
        }
        let expenseIds = Set(baseCategories.filter { showHidden || !$0.hidden }.map(\.id))

        // Monthly expenses (expenses are negative; flip to positive spend).
        var expenseByMonth: [Int: Int] = [:]
        for t in live {
            guard let categoryId = t.categoryId, expenseIds.contains(categoryId) else { continue }
            let m = monthIndex(ofYMD: t.date)
            guard start <= m, m <= end else { continue }
            expenseByMonth[m, default: 0] += -t.amount
        }

        // Running balances of the selected accounts per month. Upstream seeds
        // each account with its balance through the end of the start month,
        // then applies per-month deltas; summing across accounts commutes.
        let incomeSet = Set(incomeAccountIds)
        var startingBalance = 0
        var deltas = [Int](repeating: 0, count: months.count)
        for t in live where incomeSet.contains(t.accountId) {
            let m = monthIndex(ofYMD: t.date)
            if m <= start {
                startingBalance += t.amount
            } else if m <= end {
                deltas[m - start] += t.amount
            }
        }
        var historicalBalances = [Int]()
        var running = startingBalance
        for i in months.indices {
            if i > 0 { running += deltas[i] }
            historicalBalances.append(running)
        }

        let monthlySWR = (meta?.safeWithdrawalRate ?? 0.04) / 12

        var points: [CrossoverPoint] = []
        for (i, m) in months.enumerated() {
            let balance = historicalBalances[i]
            points.append(CrossoverPoint(
                month: monthDate(m),
                investmentIncomeCents: jsRound(Double(balance) * monthlySWR),
                expensesCents: expenseByMonth[m] ?? 0,
                nestEggCents: balance,
                adjustedExpensesCents: nil,
                isProjection: false
            ))
        }
        let lastBalance = historicalBalances.last ?? 0
        let lastExpense = expenseByMonth[end] ?? 0

        // Default monthly return: CAGR of the selected accounts' total balance.
        var defaultMonthlyReturn: Double?
        if historicalBalances.count >= 2 {
            var startBalance = Double(historicalBalances[0])
            let finalBalance = Double(historicalBalances.last!)
            let n = historicalBalances.count - 1
            if startBalance == 0 {
                if let firstNonZero = historicalBalances.dropFirst().first(where: { $0 != 0 }) {
                    startBalance = Double(firstNonZero)
                }
            }
            if startBalance > 0, finalBalance > 0 {
                let cagr = pow(finalBalance / startBalance, 1.0 / Double(n)) - 1
                defaultMonthlyReturn = cagr.isFinite ? cagr : 0
            } else {
                defaultMonthlyReturn = 0
            }
        }

        let monthlyReturn: Double?
        if let annualReturn = meta?.estimatedReturn {
            monthlyReturn = pow(1 + annualReturn, 1.0 / 12) - 1
        } else {
            monthlyReturn = defaultMonthlyReturn
        }
        let monthlyContribution = meta?.expectedContribution ?? 0
        let adjustmentFactor = meta?.expenseAdjustmentFactor ?? 1.0

        // Forward projection: flat expenses per projectionType, balance grows
        // by contribution then return, up to 600 months or crossover.
        var crossoverIndex: Int?
        let y = months.map { Double(expenseByMonth[$0] ?? 0) }
        let flatExpense: Double
        switch meta?.projectionType ?? .hampel {
        case .hampel: flatExpense = hampelFilteredMedian(y)
        case .median: flatExpense = median(y)
        case .mean: flatExpense = mean(y)
        }

        var projectedBalance = Double(lastBalance)
        var cursor = end
        for i in 1...600 {
            cursor += 1
            // Upstream adds the contribution BEFORE applying growth.
            projectedBalance += monthlyContribution
            if let monthlyReturn {
                projectedBalance *= (1 + monthlyReturn)
            }
            let projectedIncome = projectedBalance * monthlySWR
            let projectedExpenses = max(0, flatExpense)
            let adjustedExpenses = projectedExpenses * adjustmentFactor

            points.append(CrossoverPoint(
                month: monthDate(cursor),
                investmentIncomeCents: jsRound(projectedIncome),
                expensesCents: jsRound(projectedExpenses),
                nestEggCents: jsRound(projectedBalance),
                adjustedExpensesCents: jsRound(adjustedExpenses),
                isProjection: true
            ))

            // Crossover is checked against ADJUSTED expenses, projection only.
            if jsRound(projectedIncome) >= jsRound(adjustedExpenses) {
                crossoverIndex = months.count + (i - 1)
                break
            }
        }

        var crossoverMonth: Date?
        var yearsToRetire: Double?
        var targetMonthlyIncome: Int?
        var targetNestEgg: Int?
        if let crossoverIndex, crossoverIndex < points.count {
            let crossoverPoint = points[crossoverIndex]
            crossoverMonth = crossoverPoint.month
            // Upstream measures whole months from "now" to the crossover month
            // (date-fns parse reuses today's day-of-month), floored at 0.
            let monthsDiff = (start + crossoverIndex) - currentMonth
            yearsToRetire = monthsDiff > 0 ? Double(monthsDiff) / 12 : 0
            targetMonthlyIncome = crossoverPoint.adjustedExpensesCents
            if let targetMonthlyIncome, monthlySWR > 0 {
                targetNestEgg = jsRound(Double(targetMonthlyIncome) / monthlySWR)
            }
        }

        return CrossoverData(
            points: points,
            crossoverMonth: crossoverMonth,
            lastKnownBalanceCents: lastBalance,
            lastKnownMonthlyIncomeCents: jsRound(Double(lastBalance) * monthlySWR),
            lastKnownMonthlyExpensesCents: lastExpense,
            historicalReturn: defaultMonthlyReturn.map { pow(1 + $0, 12) - 1 },
            yearsToRetire: yearsToRetire,
            targetMonthlyIncomeCents: targetMonthlyIncome,
            targetNestEggCents: targetNestEgg
        )
    }

    // MARK: - Statistics (upstream Hampel identifier utilities)

    static func median(_ values: [Double]) -> Double {
        if values.isEmpty { return 0 }
        if values.count == 1 { return values[0] }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// Median after rejecting outliers beyond median ± 3 * 1.4826 * MAD.
    static func hampelFilteredMedian(_ expenses: [Double]) -> Double {
        if expenses.isEmpty { return 0 }
        if expenses.count == 1 { return expenses[0] }
        let med = median(expenses)
        let mad = median(expenses.map { abs($0 - med) })
        let threshold = 3.0
        let lowerBound = med - 1.4826 * mad * threshold
        let upperBound = med + 1.4826 * mad * threshold
        return median(expenses.filter { $0 >= lowerBound && $0 <= upperBound })
    }

    // MARK: - Month helpers

    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private static func monthIndex(of date: Date) -> Int {
        let c = calendar.dateComponents([.year, .month], from: date)
        return (c.year ?? 0) * 12 + (c.month ?? 1) - 1
    }

    private static func monthIndex(ofYMD date: Int) -> Int {
        let ym = date / 100
        return (ym / 100) * 12 + (ym % 100) - 1
    }

    private static func monthDate(_ index: Int) -> Date {
        calendar.date(from: DateComponents(year: index / 12, month: index % 12 + 1, day: 1))!
    }

    /// Parses "YYYY-MM" or "YYYY-MM-DD" to a month index.
    private static func parseMonthIndex(_ s: String?) -> Int? {
        guard let s, s.count >= 7,
              let year = Int(s.prefix(4)),
              let month = Int(s.dropFirst(5).prefix(2)),
              (1...12).contains(month) else { return nil }
        return year * 12 + month - 1
    }

    /// JS Math.round (half toward +infinity), for upstream parity.
    private static func jsRound(_ x: Double) -> Int {
        Int((x + 0.5).rounded(.down))
    }
}
