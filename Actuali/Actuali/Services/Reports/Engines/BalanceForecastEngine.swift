import Foundation

// MARK: - Meta

/// Mirrors upstream `BalanceForecastWidget` meta (loot-core dashboard.ts).
struct BalanceForecastMeta: Codable, Equatable {
    let name: String?
    let startDate: String?
    let endDate: String?
    let accounts: [String]?
    let conditions: [WidgetRuleCondition]?
    let conditionsOp: String?
    let timeFrame: WidgetTimeFrame?
    let granularity: Granularity?
    let source: Source?

    enum Granularity: String, Codable {
        case daily = "Daily"
        case monthly = "Monthly"
    }

    enum Source: String, Codable {
        case schedules
        case trackingBudget = "tracking-budget"
    }
}

// MARK: - Inputs

/// One month of tracking-budget totals, derived from `reflect_budgets`
/// (month YYYYMM, category, amount — integer cents). Mirrors the upstream
/// sheet cells (forecast-tracking-budget.ts): `budgetedIncomeCents` =
/// 'total-budget-income' (sum of budgeted amounts across income categories),
/// `budgetedExpensesCents` = 'total-budgeted' (sum across expense
/// categories, positive). Months missing from the array count as zero.
struct BalanceForecastBudgetMonth: Equatable {
    let month: Int  // YYYYMM
    let budgetedIncomeCents: Int
    let budgetedExpensesCents: Int
}

// MARK: - Output

struct BalanceForecastPoint: Equatable {
    /// The sampled day: each day for Daily, the last day of the month for
    /// Monthly (upstream keys monthly points by month; the balance is the
    /// month-end balance either way).
    let date: Date
    let balanceCents: Int
    /// True when the sampled day is after `today` — the projected segment.
    let isForecast: Bool
}

struct BalanceForecastData: Equatable {
    let points: [BalanceForecastPoint]
}

// MARK: - Engine

/// Port of upstream's balance forecast at dashboard-card fidelity:
/// loot-core `forecast/` (projection, schedules, tracking-budget) combined
/// with desktop-client `balanceForecastChartData.ts`.
///
/// Integrator wiring:
/// - `transactions`: all live transactions (the engine applies account
///   selection and widget conditions itself).
/// - `schedules`: alive, non-completed schedules regardless of
///   `posts_transaction` (the forecast projects manual schedules too, so
///   `fetchPostableSchedules` needs a variant without that flag filter).
/// - `trackingBudgetMonths`: see `BalanceForecastBudgetMonth`; only needed
///   for `source == .trackingBudget`, and the integrator must fall back to
///   `.schedules` when the budget file isn't a tracking budget (card parity
///   with the `budgetType` pref check in BalanceForecastCard.tsx).
/// - `offBudgetAccountIds`: used by the tracking-budget starting balance.
/// - `transferAccountsByPayeeId`: payee id → `payees.transfer_acct` (non-null
///   rows only), so transfer schedules project both legs.
///
/// Deliberate cuts from upstream (card fidelity):
/// - No rule-running on simulated occurrences (upstream `runRules`); the
///   schedule's own account/payee/category feed the condition filter directly.
/// - Posted-occurrence dedup always matches the exact occurrence date;
///   upstream widens to a 2-day lookback for `isapprox` manual schedules.
/// - Accountless schedules are excluded (the app's schedule model requires
///   an account condition; upstream's `includeAccountlessSchedules`).
enum BalanceForecastEngine {

    static func compute(
        meta: BalanceForecastMeta?,
        transactions: [Transaction],
        schedules: [Schedule] = [],
        trackingBudgetMonths: [BalanceForecastBudgetMonth] = [],
        offBudgetAccountIds: Set<String> = [],
        transferAccountsByPayeeId: [String: String] = [:],
        today: Date,
        context: ConditionsFilter.Context = .empty
    ) -> BalanceForecastData {
        let todayDay = dayDate(from: today)
        let (chartStart, chartEnd) = resolveRange(meta?.timeFrame, asOf: today)
        guard chartStart <= chartEnd else { return BalanceForecastData(points: []) }

        // The forecast query always covers whole months; the chart trims
        // back to the requested bounds (BalanceForecastCard.tsx).
        let forecastStart = DayDate(year: chartStart.year, month: chartStart.month, day: 1)
        let forecastEnd = DayDate(
            year: chartEnd.year, month: chartEnd.month,
            day: DayDate.lastDay(year: chartEnd.year, month: chartEnd.month)
        )

        let combinedByDay: [Int: Int]
        if meta?.source == .trackingBudget {
            combinedByDay = trackingBudgetSeries(
                transactions: transactions,
                months: trackingBudgetMonths,
                offBudgetAccountIds: offBudgetAccountIds,
                forecastStart: forecastStart,
                forecastEnd: forecastEnd
            )
        } else {
            if let selected = meta?.accounts, selected.isEmpty {
                return BalanceForecastData(points: [])
            }
            combinedByDay = schedulesSeries(
                meta: meta,
                transactions: transactions,
                schedules: schedules,
                transferAccountsByPayeeId: transferAccountsByPayeeId,
                forecastStart: forecastStart,
                forecastEnd: forecastEnd,
                today: todayDay,
                context: context
            )
        }

        let granularity = meta?.granularity ?? .monthly
        return BalanceForecastData(points: chartPoints(
            combinedByDay: combinedByDay,
            granularity: granularity,
            chartStart: chartStart,
            chartEnd: chartEnd,
            today: todayDay
        ))
    }

    // MARK: - Schedules source

    /// Combined running balance per day over the whole forecast range:
    /// posted history plus projected schedule occurrences from
    /// `firstForecastDate` (= max(start, today)) onward. Port of
    /// `projectForecastData` (forecast-projection.ts), collapsed to the
    /// combined series the card renders.
    private static func schedulesSeries(
        meta: BalanceForecastMeta?,
        transactions: [Transaction],
        schedules: [Schedule],
        transferAccountsByPayeeId: [String: String],
        forecastStart: DayDate,
        forecastEnd: DayDate,
        today: DayDate,
        context: ConditionsFilter.Context
    ) -> [Int: Int] {
        let selected = meta?.accounts.map { Set($0) }
        func inSelection(_ accountId: String) -> Bool { selected?.contains(accountId) ?? true }

        let filtered = transactions
            .filter { !$0.tombstone }
            .filter { inSelection($0.accountId) }
            .filter { ConditionsFilter.matches(transaction: $0, conditions: meta?.conditions, op: meta?.conditionsOp, context: context) }

        var startingBalance = 0
        var deltaByDay: [Int: Int] = [:]
        for tx in filtered {
            if tx.date < forecastStart.yyyymmdd {
                startingBalance += tx.amount
            } else if tx.date <= forecastEnd.yyyymmdd {
                deltaByDay[tx.date, default: 0] += tx.amount
            }
        }

        // Posted-occurrence dedup index (shared/schedules
        // indexPostedScheduleTransactions; upstream also builds it from the
        // account+condition-filtered set).
        var postedDatesBySchedule: [String: [Int]] = [:]
        for tx in filtered {
            if let scheduleId = tx.schedule {
                postedDatesBySchedule[scheduleId, default: []].append(tx.date)
            }
        }

        // Past-due occurrences before today never project (firstForecastDate
        // in forecast-projection.ts).
        let firstForecast = forecastEnd < today ? forecastStart : max(forecastStart, today)

        func addOccurrenceLeg(accountId: String, amount: Int, payeeId: String?, categoryId: String?, date: DayDate) {
            guard inSelection(accountId) else { return }
            let simulated = Transaction(
                id: "forecast", accountId: accountId, date: date.yyyymmdd, amount: amount,
                payeeId: payeeId, payeeName: nil, categoryId: categoryId, categoryName: nil,
                notes: nil, cleared: false, reconciled: false,
                transferId: nil, isParent: false, parentId: nil,
                tombstone: false, sortOrder: nil, importedPayee: nil
            )
            guard ConditionsFilter.matches(transaction: simulated, conditions: meta?.conditions, op: meta?.conditionsOp, context: context) else { return }
            deltaByDay[date.yyyymmdd, default: 0] += amount
        }

        // Schedules are NOT pre-filtered by account: when only the transfer
        // side is selected, its leg still projects (forecast-schedules.ts).
        for schedule in schedules {
            let amount = schedule.amount?.postAmount ?? 0
            let posted = postedDatesBySchedule[schedule.id] ?? []
            for date in occurrenceDates(for: schedule, endDate: forecastEnd) {
                guard date >= firstForecast, date <= forecastEnd else { continue }
                guard !posted.contains(date.yyyymmdd) else { continue }
                addOccurrenceLeg(
                    accountId: schedule.accountId, amount: amount,
                    payeeId: schedule.payeeId, categoryId: schedule.categoryId, date: date
                )
                if let payeeId = schedule.payeeId,
                   let transferAccountId = transferAccountsByPayeeId[payeeId],
                   transferAccountId != schedule.accountId {
                    addOccurrenceLeg(
                        accountId: transferAccountId, amount: -amount,
                        payeeId: nil, categoryId: nil, date: date
                    )
                }
            }
        }

        var series: [Int: Int] = [:]
        var running = startingBalance
        var day = forecastStart
        while day <= forecastEnd {
            running += deltaByDay[day.yyyymmdd] ?? 0
            series[day.yyyymmdd] = running
            day = day.adding(days: 1)
        }
        return series
    }

    /// Port of `getFutureOccurrenceDates` (forecast-schedules.ts): the stored
    /// next date, then recurrence expansion through `endDate`.
    private static func occurrenceDates(for schedule: Schedule, endDate: DayDate) -> [DayDate] {
        switch schedule.dateCondition {
        case .fixed(let date):
            return date <= endDate ? [date] : []
        case .unsupported:
            // Recurrence shape the port can't expand; the stored next_date is
            // still a real upcoming occurrence, so project that one (mirrors
            // the poster's post-once-without-advancing behavior).
            return schedule.nextDate <= endDate ? [schedule.nextDate] : []
        case .recurring(let config):
            var dates = [schedule.nextDate]
            var seen: Set<DayDate> = [schedule.nextDate]
            var day = schedule.nextDate
            var iterations = 0
            while day <= endDate, iterations < 10_000 {
                iterations += 1
                guard let next = ScheduleRecurrence.nextOccurrence(config: config, onOrAfter: day),
                      next <= endDate
                else { break }
                // getNextDate can return an already-seen date (ended schedule
                // fallback, weekend solve); step a day forward like upstream.
                if seen.contains(next) {
                    day = day.adding(days: 1)
                    continue
                }
                dates.append(next)
                seen.insert(next)
                day = next.adding(days: 1)
            }
            return dates
        }
    }

    // MARK: - Tracking-budget source

    /// Port of `projectTrackingBudgetForecast` (forecast-tracking-budget.ts):
    /// current on-budget balance, then one month-end point per month adding
    /// budgeted income minus budgeted expenses. Ignores account selection and
    /// conditions, like upstream.
    private static func trackingBudgetSeries(
        transactions: [Transaction],
        months: [BalanceForecastBudgetMonth],
        offBudgetAccountIds: Set<String>,
        forecastStart: DayDate,
        forecastEnd: DayDate
    ) -> [Int: Int] {
        var running = transactions
            .filter { !$0.tombstone && !offBudgetAccountIds.contains($0.accountId) }
            .reduce(0) { $0 + $1.amount }

        var byMonth: [Int: BalanceForecastBudgetMonth] = [:]
        for month in months { byMonth[month.month] = month }

        var series: [Int: Int] = [:]
        for (year, month) in monthsInclusive(from: forecastStart, to: forecastEnd) {
            let entry = byMonth[year * 100 + month]
            running += (entry?.budgetedIncomeCents ?? 0) - (entry?.budgetedExpensesCents ?? 0)
            let lastDay = DayDate(year: year, month: month, day: DayDate.lastDay(year: year, month: month))
            series[lastDay.yyyymmdd] = running
        }
        return series
    }

    // MARK: - Chart data

    /// Port of `buildBalanceForecastChartData` (balanceForecastChartData.ts).
    private static func chartPoints(
        combinedByDay: [Int: Int],
        granularity: BalanceForecastMeta.Granularity,
        chartStart: DayDate,
        chartEnd: DayDate,
        today: DayDate
    ) -> [BalanceForecastPoint] {
        guard !combinedByDay.isEmpty else { return [] }

        switch granularity {
        case .daily:
            // Carry the balance forward from the latest point before the
            // visible range, so a day-shaped start doesn't begin at zero.
            var running = combinedByDay
                .filter { $0.key < chartStart.yyyymmdd }
                .max { $0.key < $1.key }?.value ?? 0
            var points: [BalanceForecastPoint] = []
            var day = chartStart
            while day <= chartEnd {
                if let balance = combinedByDay[day.yyyymmdd] { running = balance }
                points.append(BalanceForecastPoint(date: date(from: day), balanceCents: running, isForecast: day > today))
                day = day.adding(days: 1)
            }
            return points

        case .monthly:
            // Latest balance within each month; months with no data carry the
            // running balance (which starts at zero — upstream monthly has no
            // prior-range carry).
            var latestKeyByMonth: [Int: Int] = [:]
            for key in combinedByDay.keys {
                let month = key / 100
                if key > latestKeyByMonth[month] ?? 0 { latestKeyByMonth[month] = key }
            }
            var running = 0
            return monthsInclusive(from: chartStart, to: chartEnd).map { year, month in
                if let key = latestKeyByMonth[year * 100 + month], let balance = combinedByDay[key] {
                    running = balance
                }
                let lastDay = DayDate(year: year, month: month, day: DayDate.lastDay(year: year, month: month))
                return BalanceForecastPoint(date: date(from: lastDay), balanceCents: running, isForecast: lastDay > today)
            }
        }
    }

    // MARK: - Dates

    private static func resolveRange(_ timeFrame: WidgetTimeFrame?, asOf today: Date) -> (DayDate, DayDate) {
        if let timeFrame {
            let (start, end) = TimeFrame.resolve(timeFrame, asOf: today)
            return (dayDate(from: start), dayDate(from: end))
        }
        // Card default: current month through 11 months ahead
        // (BalanceForecastCard.tsx defaultTimeFrame).
        let now = dayDate(from: today)
        let start = DayDate(year: now.year, month: now.month, day: 1)
        let totalMonths = (now.month - 1) + 11
        let endYear = now.year + totalMonths / 12
        let endMonth = totalMonths % 12 + 1
        let end = DayDate(year: endYear, month: endMonth, day: DayDate.lastDay(year: endYear, month: endMonth))
        return (start, end)
    }

    private static func monthsInclusive(from start: DayDate, to end: DayDate) -> [(year: Int, month: Int)] {
        var result: [(Int, Int)] = []
        var year = start.year
        var month = start.month
        while year < end.year || (year == end.year && month <= end.month) {
            result.append((year, month))
            month += 1
            if month > 12 { month = 1; year += 1 }
        }
        return result
    }

    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private static func dayDate(from date: Date) -> DayDate {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return DayDate(year: c.year!, month: c.month!, day: c.day!)
    }

    private static func date(from day: DayDate) -> Date {
        utcCalendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
    }
}
