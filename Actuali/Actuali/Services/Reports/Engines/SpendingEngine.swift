import Foundation

struct SpendingData: Equatable {
    let currentSpentCents: Int    // positive
    let comparisonCents: Int      // positive
}

/// Port of the webapp's spending-spreadsheet.ts + SpendingCard.tsx. The card
/// shows the compare month's cumulative spending at "today's day" against a
/// comparison: another month (single-month), an average over a configurable
/// window (average), or the month's budget (budget). Spending is the NET of
/// all matching transactions (refunds count), with income categories and
/// off-budget accounts already removed by the caller (spendingScope).
enum SpendingEngine {

    static func compute(
        meta: SpendingMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context = .empty
    ) -> SpendingData {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let live = transactions.filter { !$0.tombstone }
        let filtered = live
            .filter { ConditionsFilter.matches(transaction: $0, conditions: meta?.conditions, op: meta?.conditionsOp, context: context) }

        let monthComponents = cal.dateComponents([.year, .month], from: today)
        guard let currentMonthStart = cal.date(from: DateComponents(
            year: monthComponents.year, month: monthComponents.month, day: 1
        )) else { return SpendingData(currentSpentCents: 0, comparisonCents: 0) }

        let (compareStart, compareToStart) = resolveMonths(
            meta: meta, currentMonthStart: currentMonthStart, calendar: cal
        )

        let todayDay = cal.component(.day, from: today)
        let isCurrentCompare = compareStart == currentMonthStart

        // Upstream's card reads the cumulative at today's day of the compare
        // month; a past compare month reads the day-28 bucket, i.e. the full
        // month (SpendingCard.tsx todayDay). Comparison values use the same
        // day so current-vs-past is month-to-date against month-to-same-date,
        // except past day 28 where prior months use their full totals.
        let current = monthSpending(transactions: filtered,
                                    monthStart: compareStart,
                                    calendar: cal,
                                    throughDay: isCurrentCompare ? todayDay : nil)
        let sameDayCutoff: Int? = (isCurrentCompare && todayDay < 28) ? todayDay : nil

        let comparison: Int
        switch meta?.mode ?? .singleMonth {
        case .singleMonth:
            comparison = monthSpending(transactions: filtered,
                                       monthStart: compareToStart,
                                       calendar: cal,
                                       throughDay: sameDayCutoff)
        case .budget:
            // Budget-mode target needs zero_budgets/reflect_budgets data that
            // isn't plumbed into the engine yet; the widget shows spending only.
            comparison = 0
        case .average:
            comparison = averageSpending(transactions: filtered,
                                         allTransactions: live,
                                         compareStart: compareStart,
                                         range: meta?.averageRange,
                                         throughDay: sameDayCutoff,
                                         calendar: cal)
        }

        return SpendingData(currentSpentCents: current, comparisonCents: comparison)
    }

    /// Port of calculateSpendingReportTimeRange (reportRanges.ts): live
    /// budget/average pin to the stored compare month or the current one;
    /// live single-month with a stored compare uses it (and compareTo, else
    /// the month before); otherwise a live window slides to end at the
    /// current month while a static one keeps its stored months verbatim.
    private static func resolveMonths(
        meta: SpendingMeta?,
        currentMonthStart: Date,
        calendar: Calendar
    ) -> (compare: Date, compareTo: Date) {
        let isLive = meta?.isLive ?? true
        let mode = meta?.mode ?? .singleMonth
        let stored = parseMonthStart(from: meta?.compare, calendar: calendar)
        let storedTo = parseMonthStart(from: meta?.compareTo, calendar: calendar)

        func prevMonth(_ d: Date) -> Date {
            calendar.date(byAdding: .month, value: -1, to: d) ?? d
        }

        if (mode == .budget || mode == .average) && isLive {
            let compare = stored ?? currentMonthStart
            return (compare, prevMonth(compare))
        }
        if mode == .singleMonth, isLive, let stored {
            return (stored, storedTo ?? prevMonth(stored))
        }
        if isLive {
            // Sliding window: compare is the current month; compareTo keeps
            // its stored month (clamped), defaulting to the previous month.
            let to = storedTo ?? prevMonth(currentMonthStart)
            return (currentMonthStart, min(to, currentMonthStart))
        }
        let compare = stored ?? currentMonthStart
        return (compare, storedTo ?? prevMonth(compare))
    }

    /// Net spending for one month as positive cents. `throughDay` limits to a
    /// month-to-date cumulative; nil sums the whole month.
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
        let net = transactions
            .filter { $0.date >= startYMD && $0.date <= endYMD }
            .reduce(0) { $0 + $1.amount }
        return -net
    }

    /// Average cumulative spending across the months of the configured range
    /// (resolveSpendingAverageRange upstream): the range ends the month
    /// before `compareStart`; months with no transactions still count in the
    /// divisor.
    private static func averageSpending(
        transactions: [Transaction],
        allTransactions: [Transaction],
        compareStart: Date,
        range: SpendingAverageRange?,
        throughDay: Int?,
        calendar: Calendar
    ) -> Int {
        guard let endMonth = calendar.date(byAdding: .month, value: -1, to: compareStart) else { return 0 }

        // Unsupported last-n values normalize to the 3-month default upstream.
        let supportedMonths: Set<Int> = [3, 6, 12]
        let startMonth: Date?
        switch range?.mode {
        case "year-to-date":
            startMonth = calendar.date(from: DateComponents(
                year: calendar.component(.year, from: compareStart), month: 1, day: 1))
        case "all-time":
            // ponytail: earliest month derived from the transactions given to
            // the engine; upstream queries the globally earliest transaction.
            startMonth = allTransactions.map(\.date).min().flatMap { ymd in
                calendar.date(from: DateComponents(year: ymd / 10000, month: (ymd % 10000) / 100, day: 1))
            }
        default:
            let n = range?.months.flatMap { supportedMonths.contains($0) ? $0 : nil } ?? 3
            startMonth = calendar.date(byAdding: .month, value: -n, to: compareStart)
        }

        guard let startMonth, startMonth <= endMonth else { return 0 }

        var sum = 0
        var count = 0
        var month = startMonth
        while month <= endMonth {
            sum += monthSpending(transactions: transactions,
                                 monthStart: month,
                                 calendar: calendar,
                                 throughDay: throughDay)
            count += 1
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            month = next
        }
        guard count > 0 else { return 0 }
        return Int((Double(sum) / Double(count)).rounded())
    }

    private static func parseMonthStart(from string: String?, calendar: Calendar) -> Date? {
        // Accept "YYYY-MM" or "YYYY-MM-DD"
        guard let string else { return nil }
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
