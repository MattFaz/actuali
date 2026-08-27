import Foundation

/// A schedule as the goal-template engine sees it — the slice of
/// `ScheduleSummary` the `#template schedule` math needs.
struct GoalScheduleInfo: Sendable {
    let id: String
    let name: String?
    let completed: Bool
    /// The rule's amount condition; nil posts as 0 upstream.
    let amount: ScheduledAmount?
    let dateCondition: ScheduleDateCondition?
}

/// Port of loot-core `schedule-template.ts`: how much a category's schedule
/// templates want budgeted this month. Pure — all schedule data arrives
/// pre-fetched.
///
/// ponytail: upstream also runs the schedule's *rule actions* here so a rule
/// that splits the scheduled transaction (or sets a templated amount) budgets
/// only this category's split legs. Actuali's RulesEngine doesn't support
/// split actions yet (see RulesEngine.swift), so this port targets the
/// schedule's plain amount condition; upgrade path is wiring RulesEngine in
/// once it learns `set-split-amount`.
enum GoalTemplateSchedules {

    struct ScheduleTarget {
        let template: GoalTemplate
        var target: Int
        let nextDateString: String // "yyyy-MM-dd"
        let targetInterval: Int
        let targetFrequency: String? // RecurConfig frequency, nil for one-offs
        let numMonths: Int
        let full: Bool
        let repeating: Bool
    }

    /// Upstream's `isbetween` average: `Math.round(num1 + num2) / 2`, adjusted,
    /// then rounded — kept in that exact order because percent adjustments see
    /// the unrounded midpoint.
    static func scheduleAmount(_ amount: ScheduledAmount?, template: GoalTemplate) -> Int {
        var value: Double
        switch amount {
        case .fixed(let cents): value = Double(cents)
        case .range(let num1, let num2): value = Double(num1 + num2) / 2
        case nil: value = 0
        }
        if let adjustment = template.adjustment, let adjustmentType = template.adjustmentType {
            switch adjustmentType {
            case .percent:
                value *= 1 + adjustment / 100
            case .fixed:
                let sign: Double = value < 0 ? -1 : 1
                value += sign * Double(BudgetMonthMath.amountToInteger(adjustment))
            }
        }
        return BudgetMonthMath.jsRound(value)
    }

    /// Port of `createScheduleList`. Completed and past-dated schedules drop
    /// out (upstream records errors for them that the caller then discards).
    static func createScheduleList(
        templates: [GoalTemplate],
        currentMonth: String,
        categoryIsIncome: Bool,
        schedules: [GoalScheduleInfo]
    ) -> [ScheduleTarget] {
        let monthStart = BudgetMonthMath.day(currentMonth) ?? .today()
        var targets: [ScheduleTarget] = []

        for template in templates where template.type == .schedule {
            // Prefer scheduleId (UI-managed templates) so renames don't break
            // the lookup; fall back to the trimmed name for notes templates.
            let schedule: GoalScheduleInfo?
            if let scheduleId = template.scheduleId {
                schedule = schedules.first { $0.id == scheduleId }
            } else if let name = template.name?.trimmingCharacters(in: .whitespaces) {
                schedule = schedules.first {
                    $0.name?.trimmingCharacters(in: .whitespaces) == name
                }
            } else {
                schedule = nil
            }
            guard let schedule else { continue }

            let amount = scheduleAmount(schedule.amount, template: template)

            var nextDate: DayDate?
            var targetInterval = 1
            var targetFrequency: String?
            var repeating = false
            var recurConfig: RecurConfig?
            switch schedule.dateCondition {
            case .fixed(let day):
                nextDate = day
            case .recurring(let config):
                nextDate = ScheduleRecurrence.nextOccurrence(config: config, onOrAfter: monthStart)
                targetInterval = config.interval
                targetFrequency = config.frequency.rawValue
                repeating = true
                recurConfig = config
            case .unsupported, nil:
                nextDate = nil
            }
            guard let nextDate else { continue }

            let numMonths = BudgetMonthMath.differenceInCalendarMonths(nextDate.iso, currentMonth)
            // Past one-offs error out upstream ("Schedule X is in the Past"),
            // completed ones error as inactive — both contribute nothing.
            guard numMonths >= 0, !schedule.completed else { continue }

            let sign = categoryIsIncome ? 1 : -1
            var target = sign * amount

            if repeating, let config = recurConfig {
                target = monthlyRepeatTarget(
                    config: config,
                    monthStart: monthStart,
                    boundaryMonth: BudgetMonthMath.addMonths(currentMonth, numMonths + 1),
                    perOccurrence: target)
            }

            targets.append(ScheduleTarget(
                template: template,
                target: target,
                nextDateString: nextDate.iso,
                targetInterval: targetInterval,
                targetFrequency: targetFrequency,
                numMonths: numMonths,
                full: template.full ?? false,
                repeating: repeating))
        }
        return targets
    }

    /// Sum of all occurrences that land before `boundaryMonth` — upstream's
    /// while-loop over `getNextDate(..., noSkipWeekend: true)` with the
    /// weekend solve applied manually to the comparison date.
    private static func monthlyRepeatTarget(
        config: RecurConfig,
        monthStart: DayDate,
        boundaryMonth: String,
        perOccurrence: Int
    ) -> Int {
        // Base dates iterate without the weekend shift; only the compared
        // date is shifted, mirroring getNextDate's noSkipWeekend flag.
        let baseConfig = RecurConfig(
            frequency: config.frequency, interval: config.interval, start: config.start,
            patterns: config.patterns, skipWeekend: false,
            weekendSolveMode: config.weekendSolveMode, endMode: config.endMode,
            endOccurrences: config.endOccurrences, endDate: config.endDate)

        func solved(_ date: DayDate) -> DayDate {
            guard config.skipWeekend, date.isWeekend else { return date }
            return config.weekendSolveMode == "before"
                ? previousFriday(from: date) : ScheduleRecurrence.nextMonday(from: date)
        }

        var total = 0
        guard var baseDate = ScheduleRecurrence.nextOccurrence(config: baseConfig, onOrAfter: monthStart)
        else { return 0 }
        var comparisonDate = solved(baseDate)
        // Lexicographic "yyyy-MM-dd" < "yyyy-MM" boundary compare, as upstream.
        while comparisonDate.iso < boundaryMonth {
            total += perOccurrence
            let currentDate = baseDate
            guard let next = ScheduleRecurrence.nextOccurrence(
                config: baseConfig, onOrAfter: baseDate.adding(days: 1))
            else { break }
            baseDate = next
            comparisonDate = solved(baseDate)
            // An exhausted bounded schedule keeps returning its last
            // occurrence; upstream breaks on the zero-day difference.
            if currentDate.days(until: baseDate) == 0 { break }
        }
        return total
    }

    private static func previousFriday(from date: DayDate) -> DayDate {
        var result = date
        while result.weekday != 6 { result = result.adding(days: -1) }
        return result
    }

    // MARK: - runSchedule

    /// Port of `runSchedule`'s budgeting math. Returns the new to-budget total
    /// for the category (the caller subtracts what was already accumulated).
    static func run(
        templates: [GoalTemplate],
        currentMonth: String,
        balance: Int,
        lastMonthBalance: Int,
        toBudget: Int,
        lastMonthGoal: Int,
        categoryIsIncome: Bool,
        isTracking: Bool,
        schedules: [GoalScheduleInfo]
    ) -> Int {
        var toBudget = toBudget
        let targets = createScheduleList(
            templates: templates, currentMonth: currentMonth,
            categoryIsIncome: categoryIsIncome, schedules: schedules)

        func isPayMonthOf(_ c: ScheduleTarget) -> Bool {
            c.full
                || ((c.targetFrequency == "monthly" || c.targetFrequency == nil)
                    && c.targetInterval == 1 && c.numMonths == 0)
                || (c.targetFrequency == "weekly" && c.targetInterval <= 4)
                || (c.targetFrequency == "daily" && c.targetInterval <= 31)
                || isTracking
        }

        func isSubMonthly(_ c: ScheduleTarget) -> Bool {
            c.targetFrequency == "weekly" || c.targetFrequency == "daily"
        }

        let payMonthOf = targets.filter(isPayMonthOf)
        let sinking = targets.filter { !isPayMonthOf($0) }
            .sorted { $0.nextDateString < $1.nextDateString }
        let numSubMonthly = targets.count(where: isSubMonthly)

        let totalPayMonthOf = payMonthOf
            .filter { $0.numMonths == 0 }
            .reduce(0.0) { $0 + Double($1.target) }
        let totalSinking = sinking.reduce(0.0) { $0 + Double($1.target) }
        let totalSinkingBaseContribution = sinking.reduce(0.0) { $0 + monthlyBaseContribution($1) }

        if Double(balance) >= totalSinking + totalPayMonthOf
            || (Double(lastMonthGoal) < totalSinking + totalPayMonthOf
                && lastMonthGoal != 0
                && balance >= lastMonthGoal
                && numSubMonthly > 0) {
            toBudget += BudgetMonthMath.jsRound(totalPayMonthOf + totalSinkingBaseContribution)
        } else {
            let totalSinkingContribution = sinkingContributionTotal(
                sinking, lastMonthBalance: lastMonthBalance)
            if sinking.isEmpty {
                toBudget += BudgetMonthMath.jsRound(totalPayMonthOf + totalSinkingContribution)
                    - lastMonthBalance
            } else {
                toBudget += BudgetMonthMath.jsRound(totalPayMonthOf + totalSinkingContribution)
            }
        }
        return toBudget
    }

    /// Port of `getMonthlyBaseContribution`.
    private static func monthlyBaseContribution(_ schedule: ScheduleTarget) -> Double {
        let target = Double(schedule.target)
        let interval = Double(schedule.targetInterval)
        switch schedule.targetFrequency {
        case "yearly":
            return target / interval / 12
        case "monthly":
            return target / interval
        case "weekly":
            let previous = BudgetMonthMath.subWeeks(schedule.nextDateString, schedule.targetInterval)
            var intervalMonths = BudgetMonthMath.differenceInCalendarMonths(
                schedule.nextDateString, previous)
            if intervalMonths == 0 { intervalMonths = 1 }
            return target / Double(intervalMonths)
        case "daily":
            let previous = BudgetMonthMath.subDays(schedule.nextDateString, schedule.targetInterval)
            var intervalMonths = BudgetMonthMath.differenceInCalendarMonths(
                schedule.nextDateString, previous)
            if intervalMonths == 0 { intervalMonths = 1 }
            return target / Double(intervalMonths)
        default:
            return target / interval
        }
    }

    /// Port of `getSinkingContributionBreakdown`'s total: each schedule needs
    /// its target minus what earlier ones left behind, spread across the
    /// months until it's due.
    private static func sinkingContributionTotal(
        _ sinking: [ScheduleTarget],
        lastMonthBalance: Int
    ) -> Double {
        var total = 0.0
        var remainder = 0.0
        for (index, schedule) in sinking.enumerated() {
            remainder = index == 0
                ? Double(schedule.target - lastMonthBalance)
                : Double(schedule.target) - remainder
            var contributionTarget = 0.0
            if remainder >= 0 {
                contributionTarget = remainder
                remainder = 0
            } else {
                remainder = abs(remainder)
            }
            total += contributionTarget / Double(schedule.numMonths + 1)
        }
        return total
    }
}
