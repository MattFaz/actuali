import Foundation

/// The category slice the engine needs (upstream passes full CategoryEntity).
struct GoalTemplateCategory: Equatable, Sendable {
    let id: String
    let name: String
    let isIncome: Bool
}

/// Sheet values for the goal-template engine — the subset of loot-core's
/// spreadsheet cells the templates read, precomputed per (month, category)
/// from SQLite. Months are YYYYMM ints; amounts are cents.
struct GoalTemplateSheet: Sendable {
    struct MonthCat: Hashable, Sendable {
        let month: Int
        let category: String

        init(_ month: Int, _ category: String) {
            self.month = month
            self.category = category
        }
    }

    var isTracking = false
    var hideFraction = false
    /// `to-budget` (envelope) / `total-saved` (tracking) for the target month.
    var availableStart = 0
    /// `budget-{cat}`: budgeted amount where a budget row exists.
    var budgeted: [MonthCat: Int] = [:]
    /// `sum-amount-{cat}`: the month's net activity (negative = spending).
    var spent: [MonthCat: Int] = [:]
    /// `leftover-{cat}`: the category balance at the END of that month.
    var leftover: [MonthCat: Int] = [:]
    /// `carryover-{cat}`: rollover flag on that month's budget row.
    var carryover: Set<MonthCat> = []
    /// `goal-{cat}`: non-null goal column values.
    var goals: [MonthCat: Int] = [:]
    /// Rows whose goal or long_goal is non-null — the orphan-reset set.
    var goalRows: Set<MonthCat> = []
    /// `total-income` per month (sum of income categories' activity).
    var totalIncome: [Int: Int] = [:]
    /// Earliest YYYYMM with a budget row or on-budget activity, per category.
    var firstActivityMonth: [String: Int] = [:]

    func budgeted(month: String, category: String) -> Int {
        budgeted[MonthCat(BudgetMonthMath.monthInt(month), category)] ?? 0
    }

    func spent(month: String, category: String) -> Int {
        spent[MonthCat(BudgetMonthMath.monthInt(month), category)] ?? 0
    }

    func leftover(month: String, category: String) -> Int {
        leftover[MonthCat(BudgetMonthMath.monthInt(month), category)] ?? 0
    }

    func carryover(month: String, category: String) -> Bool {
        carryover.contains(MonthCat(BudgetMonthMath.monthInt(month), category))
    }

    func goal(month: String, category: String) -> Int {
        goals[MonthCat(BudgetMonthMath.monthInt(month), category)] ?? 0
    }

    func totalIncome(month: String) -> Int {
        totalIncome[BudgetMonthMath.monthInt(month)] ?? 0
    }
}

enum GoalTemplateError: Error {
    case category(String)
}

/// Per-category template processor — a straight port of loot-core's
/// `CategoryTemplateContext`, synchronous because every sheet value arrives
/// precomputed in `GoalTemplateSheet`.
final class GoalTemplateContext {
    let category: GoalTemplateCategory
    private let month: String
    private let sheet: GoalTemplateSheet
    private let schedules: [GoalScheduleInfo]
    private let allCategories: [GoalTemplateCategory]
    private let currentMonth: String

    /// Template lists keep the index into the caller's template array so
    /// per-template contributions (dry-run projections) can be attributed
    /// back — upstream keys its maps by object identity instead.
    private var templates: [(index: Int, template: GoalTemplate)] = []
    private var remainder: [(index: Int, template: GoalTemplate)] = []
    private var goals: [GoalTemplate] = []
    private var priorities: Set<Int> = []
    private var remainderWeight: Double = 0
    private(set) var toBudgetAmount = 0
    /// Amount budgeted per input-template index (see `templates`).
    private var perTemplateContribution: [Int: Int] = [:]
    private let skipAvailableClamp: Bool
    private var fullAmount: Int?
    private var isLongGoal: Bool?
    private var goalAmount: Int?
    private var fromLastMonth = 0
    private var limitMet = false
    private(set) var limitExcess = 0
    private var limitAmount = 0
    private var limitCheck = false
    private var limitHold = false
    let previouslyBudgeted: Int
    private let hideDecimal: Bool
    private let inputTemplateCount: Int

    struct Values {
        let budgeted: Int
        let goal: Int?
        let longGoal: Bool?
        /// Contribution per input template, aligned with the init templates
        /// array (0 for goals, limits, and templates that budgeted nothing).
        let perTemplate: [Int]
    }

    init(
        templates: [GoalTemplate],
        category: GoalTemplateCategory,
        month: String,
        budgeted: Int,
        sheet: GoalTemplateSheet,
        schedules: [GoalScheduleInfo],
        allCategories: [GoalTemplateCategory],
        currentMonth: String,
        skipAvailableClamp: Bool = false
    ) throws {
        self.category = category
        self.month = month
        self.sheet = sheet
        self.schedules = schedules
        self.allCategories = allCategories
        self.currentMonth = currentMonth
        self.skipAvailableClamp = skipAvailableClamp
        previouslyBudgeted = budgeted
        hideDecimal = sheet.hideFraction
        inputTemplateCount = templates.count

        let lastMonth = BudgetMonthMath.subMonths(month, 1)
        var fromLastMonth = sheet.leftover(month: lastMonth, category: category.id)
        let carryover = sheet.carryover(month: lastMonth, category: category.id)
        if (fromLastMonth < 0 && !carryover) // overspend without rollover
            || category.isIncome // tracking income categories
            || (sheet.isTracking && !carryover) { // tracking regular categories
            fromLastMonth = 0
        }
        self.fromLastMonth = fromLastMonth

        try Self.checkByAndScheduleAndSpend(templates: templates, month: month, schedules: schedules)
        try Self.checkPercentage(templates: templates, categories: allCategories)

        for (index, template) in templates.enumerated() {
            if template.directive == .template, template.type != .remainder, template.type != .limit {
                self.templates.append((index, template))
                if let priority = template.priority { priorities.insert(priority) }
            } else if template.directive == .template, template.type == .remainder {
                remainder.append((index, template))
                remainderWeight += template.weight ?? 1
            } else if template.directive == .goal, template.type == .goal {
                goals.append(template)
            }
        }

        try checkLimit(templates)
        try checkSpend()
        try checkGoal()
    }

    // MARK: - Interface

    func isGoalOnly() -> Bool {
        templates.isEmpty && remainder.isEmpty && !goals.isEmpty
    }

    func getPriorities() -> [Int] {
        Array(priorities)
    }

    func hasRemainder() -> Bool {
        remainderWeight > 0 && !limitMet
    }

    func getRemainderWeight() -> Double {
        remainderWeight
    }

    func runTemplatesForPriority(_ priority: Int, budgetAvail: Int, availStart: Int) throws -> Int {
        guard priorities.contains(priority), !limitMet else { return 0 }

        let priorityTemplates = templates.filter {
            $0.template.directive == .template && $0.template.priority == priority
        }
        var available = budgetAvail
        var toBudget = 0
        var byFlag = false
        var scheduleFlag = false
        // Per-template budgets for this priority pass, in iteration order —
        // the batched by/schedule totals land on the first sibling and are
        // redistributed below, mirroring upstream's perTemplateLocal map.
        var perTemplateLocal: [(index: Int, value: Int)] = []
        var byPerTemplate: [Int: Int] = [:]
        var schedulePerTemplate: [Int: Double] = [:]

        for (index, template) in priorityTemplates {
            var newBudget = 0
            switch template.type {
            case .simple:
                newBudget = runSimple(template)
            case .refill:
                newBudget = limitAmount - fromLastMonth
            case .copy:
                newBudget = runCopy(template)
            case .periodic:
                newBudget = runPeriodic(template)
            case .spend:
                newBudget = runSpend(template)
            case .percentage:
                newBudget = try runPercentage(template, availableFunds: availStart)
            case .by:
                // All `by` templates in the priority run as one batch.
                if !byFlag {
                    let result = runBy()
                    newBudget = result.toBudget
                    byPerTemplate = result.perTemplateNeed
                }
                byFlag = true
            case .schedule:
                if !scheduleFlag {
                    let lastMonth = BudgetMonthMath.subMonths(month, 1)
                    let result = GoalTemplateSchedules.run(
                        templates: priorityTemplates,
                        currentMonth: month,
                        balance: fromLastMonth + toBudget,
                        lastMonthBalance: fromLastMonth,
                        toBudget: toBudget,
                        lastMonthGoal: sheet.goal(month: lastMonth, category: category.id),
                        categoryIsIncome: category.isIncome,
                        isTracking: sheet.isTracking,
                        schedules: schedules)
                    // The schedule run returns the whole to-budget figure, so
                    // strip what earlier templates already contributed.
                    newBudget = result.toBudget - toBudget
                    schedulePerTemplate = result.perTemplate
                    scheduleFlag = true
                }
            case .average:
                newBudget = runAverage(template)
            default:
                break
            }
            available -= newBudget
            toBudget += newBudget
            perTemplateLocal.append((index, newBudget))
        }

        // Split the batched by/schedule totals across their siblings by each
        // template's own need, so per-row projections don't credit the whole
        // batch to whichever sibling ran first (upstream redistributeBatch).
        redistributeBatch(
            &perTemplateLocal,
            siblings: priorityTemplates.filter { $0.template.type == .by }.map(\.index),
            weightOf: { Double(max(0, byPerTemplate[$0] ?? 0)) })
        redistributeBatch(
            &perTemplateLocal,
            siblings: priorityTemplates.filter { $0.template.type == .schedule }.map(\.index),
            weightOf: { max(0, schedulePerTemplate[$0] ?? 0) })

        var scale = 1.0

        // Limit cap for the running total (balance carried in counts).
        if limitCheck, toBudget + toBudgetAmount + fromLastMonth >= limitAmount {
            let original = toBudget
            toBudget = limitAmount - toBudgetAmount - fromLastMonth
            limitMet = true
            available = available + original - toBudget
            if original > 0 { scale *= Double(toBudget) / Double(original) }
        }

        if hideDecimal {
            // Track the rounding delta so per-row contributions sum to the
            // engine's actual budgeted amount.
            let preRound = toBudget
            toBudget = removeFraction(toBudget)
            if preRound != 0 { scale *= Double(toBudget) / Double(preRound) }
        }

        // Don't overbudget at a positive priority unless this is an income
        // category (which credits rather than spends the pool). Dry runs skip
        // the clamp so future months show the templates' intended amount.
        if priority > 0, available < 0, !category.isIncome, !skipAvailableClamp {
            fullAmount = (fullAmount ?? 0) + toBudget
            let adjusted = max(0, toBudget + available)
            if toBudget > 0 { scale *= Double(adjusted) / Double(toBudget) }
            toBudget = adjusted
            toBudgetAmount += toBudget
        } else {
            fullAmount = (fullAmount ?? 0) + toBudget
            toBudgetAmount += toBudget
        }

        // Distribute the priority's final budget across its templates. The
        // limit branch can produce a negative scale when the carried balance
        // already exceeds the cap; floor at 0 so projections never go
        // negative. The last entry takes the residual so the shares sum to
        // toBudget exactly.
        let perRowScale = max(0, scale)
        var remaining = max(0, toBudget)
        for (position, entry) in perTemplateLocal.enumerated() {
            let isLast = position == perTemplateLocal.count - 1
            let share = isLast
                ? remaining
                : max(0, min(remaining, BudgetMonthMath.jsRound(Double(entry.value) * perRowScale)))
            perTemplateContribution[entry.index, default: 0] += share
            remaining -= share
        }
        return category.isIncome ? -toBudget : toBudget
    }

    /// Port of upstream `redistributeBatch`: zero the siblings' local values
    /// and re-split their total by weight, last sibling absorbing rounding.
    private func redistributeBatch(
        _ perTemplateLocal: inout [(index: Int, value: Int)],
        siblings: [Int],
        weightOf: (Int) -> Double
    ) {
        guard siblings.count >= 2 else { return }
        let siblingSet = Set(siblings)
        var total = 0
        for (position, entry) in perTemplateLocal.enumerated()
            where siblingSet.contains(entry.index) {
            total += entry.value
            perTemplateLocal[position].value = 0
        }
        guard total != 0 else { return }

        let totalWeight = siblings.reduce(0.0) { $0 + weightOf($1) }
        var shares: [Int: Int] = [:]
        var remaining = total
        for (position, index) in siblings.enumerated() {
            let isLast = position == siblings.count - 1
            let share: Int
            if isLast {
                share = remaining
            } else if totalWeight > 0 {
                share = BudgetMonthMath.jsRound(Double(total) * weightOf(index) / totalWeight)
            } else {
                // Equal split fallback when no weights are usable.
                share = BudgetMonthMath.jsRound(Double(total) / Double(siblings.count))
            }
            let allocated = max(0, min(share, remaining))
            shares[index] = allocated
            remaining -= allocated
        }
        for (position, entry) in perTemplateLocal.enumerated() {
            if let share = shares[entry.index] {
                perTemplateLocal[position].value = share
            }
        }
    }

    func runRemainder(budgetAvail: Int, perWeight: Double) -> Int {
        guard !remainder.isEmpty else { return 0 }
        var toBudget = BudgetMonthMath.jsRound(remainderWeight * perWeight)

        var smallest = 1
        if hideDecimal {
            toBudget = removeFraction(toBudget)
            smallest = 100
        }

        // Absorb rounding overshoot and sub-cent leftovers.
        if toBudget > budgetAvail || budgetAvail - toBudget <= smallest {
            toBudget = budgetAvail
        }

        if limitCheck, toBudget + toBudgetAmount + fromLastMonth >= limitAmount {
            toBudget = limitAmount - toBudgetAmount - fromLastMonth
            limitMet = true
        }

        // Attribute the pass across the remainder templates by weight, the
        // last one absorbing rounding (upstream runRemainder's share loop).
        if toBudget > 0, remainderWeight > 0 {
            var remaining = toBudget
            for (position, entry) in remainder.enumerated() {
                let isLast = position == remainder.count - 1
                let share = isLast
                    ? remaining
                    : BudgetMonthMath.jsRound(
                        Double(toBudget) * (entry.template.weight ?? 1) / remainderWeight)
                let allocated = max(0, min(share, remaining))
                perTemplateContribution[entry.index, default: 0] += allocated
                remaining -= allocated
            }
        }

        toBudgetAmount += toBudget
        return toBudget
    }

    func getValues() -> Values {
        runGoal()
        var perTemplate = [Int](repeating: 0, count: inputTemplateCount)
        for (index, contribution) in perTemplateContribution
            where index >= 0 && index < inputTemplateCount {
            perTemplate[index] = contribution
        }
        return Values(
            budgeted: toBudgetAmount, goal: goalAmount, longGoal: isLongGoal,
            perTemplate: perTemplate)
    }

    private func runGoal() {
        if let goal = goals.first {
            if isGoalOnly() { toBudgetAmount = previouslyBudgeted }
            isLongGoal = true
            goalAmount = BudgetMonthMath.amountToInteger(goal.amount ?? 0)
            return
        }
        goalAmount = fullAmount
    }

    // MARK: - Validation

    static func checkByAndScheduleAndSpend(
        templates: [GoalTemplate],
        month: String,
        schedules: [GoalScheduleInfo]
    ) throws {
        let byAndSchedule = templates.filter { $0.type == .schedule || $0.type == .by }
        guard !byAndSchedule.isEmpty else { return }

        let scheduleIds = Set(schedules.map(\.id))
        let scheduleNames = Set(schedules.compactMap {
            $0.name?.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty })
        for template in templates where template.type == .schedule {
            if let scheduleId = template.scheduleId {
                guard scheduleIds.contains(scheduleId) else {
                    throw GoalTemplateError.category(
                        "Schedule \(template.name ?? scheduleId) does not exist")
                }
            } else if let name = template.name {
                guard scheduleNames.contains(name.trimmingCharacters(in: .whitespaces)) else {
                    throw GoalTemplateError.category(
                        "Schedule \(name.trimmingCharacters(in: .whitespaces)) does not exist")
                }
            } else {
                throw GoalTemplateError.category("Schedule template has no scheduleId or name")
            }
        }

        let lowestPriority = byAndSchedule.compactMap(\.priority).min() ?? 0
        for template in byAndSchedule where template.priority != lowestPriority {
            throw GoalTemplateError.category(
                "Schedule and By templates must be the same priority level. Fix by setting all Schedule and By templates to priority level \(lowestPriority)")
        }

        for template in templates where template.type == .by || template.type == .spend {
            let range = BudgetMonthMath.differenceInCalendarMonths(template.month ?? "", month)
            if range < 0, template.repeatCount == nil, template.annual != true {
                throw GoalTemplateError.category(
                    "Target month has passed, remove or update the target month")
            }
        }
    }

    static func checkPercentage(
        templates: [GoalTemplate],
        categories: [GoalTemplateCategory]
    ) throws {
        let percentageTemplates = templates.filter { $0.type == .percentage }
        guard !percentageTemplates.isEmpty else { return }

        let incomeCategories = categories.filter(\.isIncome)
        let names = Set(incomeCategories.map { $0.name.lowercased() })
        let ids = Set(incomeCategories.map(\.id))
        let specialSources: Set<String> = ["all income", "available funds"]

        for template in percentageTemplates {
            let raw = template.category ?? ""
            let lowered = raw.lowercased()
            guard specialSources.contains(lowered) || names.contains(lowered)
                || ids.contains(raw) else {
                throw GoalTemplateError.category(
                    "Category \"\(raw)\" is not found in available income categories")
            }
        }
    }

    private func checkLimit(_ templates: [GoalTemplate]) throws {
        for template in templates where template.type == .simple || template.type == .periodic
            || template.type == .limit || template.type == .remainder {
            // limit-type templates carry the limit itself; the others may
            // have an attached one.
            guard let limit = template.limit else { continue }

            if limitCheck {
                throw GoalTemplateError.category("Only one `up to` allowed per category")
            }

            switch limit.period {
            case .daily:
                let numDays = BudgetMonthMath.daysInMonth(month)
                limitAmount += BudgetMonthMath.amountToInteger(limit.amount) * numDays
            case .weekly:
                guard let start = limit.start else {
                    throw GoalTemplateError.category(
                        "Weekly limit requires a start date (YYYY-MM-DD)")
                }
                let nextMonth = BudgetMonthMath.nextMonth(month)
                var week = start
                let baseLimit = BudgetMonthMath.amountToInteger(limit.amount)
                while week < nextMonth {
                    if week >= month { limitAmount += baseLimit }
                    week = BudgetMonthMath.addWeeks(week, 1)
                }
            case .monthly:
                limitAmount = BudgetMonthMath.amountToInteger(limit.amount)
            }

            limitCheck = true
            limitHold = limit.hold
            // Already over the cap: release (or hold) the excess.
            if fromLastMonth >= limitAmount {
                limitMet = true
                if limitHold {
                    limitExcess = 0
                    toBudgetAmount = 0
                    fullAmount = 0
                } else {
                    limitExcess = fromLastMonth - limitAmount
                    toBudgetAmount = -limitExcess
                    fullAmount = -limitExcess
                }
            }
        }
    }

    private func checkSpend() throws {
        if templates.count(where: { $0.template.type == .spend }) > 1 {
            throw GoalTemplateError.category("Only one spend template is allowed per category")
        }
    }

    private func checkGoal() throws {
        if goals.count > 1 {
            throw GoalTemplateError.category("Only one #goal is allowed per category")
        }
    }

    private func removeFraction(_ amount: Int) -> Int {
        BudgetMonthMath.jsRound(Double(amount) / 100) * 100
    }

    // MARK: - Processors

    private func runSimple(_ template: GoalTemplate) -> Int {
        if let monthly = template.monthly {
            return BudgetMonthMath.amountToInteger(monthly)
        }
        return limitAmount - fromLastMonth
    }

    private func runCopy(_ template: GoalTemplate) -> Int {
        let sourceMonth = BudgetMonthMath.subMonths(month, template.lookBack ?? 0)
        return sheet.budgeted(month: sourceMonth, category: category.id)
    }

    private func runPeriodic(_ template: GoalTemplate) -> Int {
        guard let period = template.period else { return 0 }
        var toBudget = 0
        let amount = BudgetMonthMath.amountToInteger(template.amount ?? 0)
        let numPeriods = period.amount
        var date = (template.starting?.isEmpty == false)
            ? template.starting! : BudgetMonthMath.firstDayOfMonth(month)

        // `addMonths` collapses a day string to "yyyy-MM" exactly like
        // upstream's month utils — the lexicographic compares below rely on it.
        let shift: (String, Int) -> String
        switch period.period {
        case .day: shift = BudgetMonthMath.addDays
        case .week: shift = BudgetMonthMath.addWeeks
        case .month: shift = BudgetMonthMath.addMonths
        case .year: shift = { BudgetMonthMath.addMonths($0, $1 * 12) }
        }

        while month > date {
            date = shift(date, numPeriods)
        }
        if BudgetMonthMath.differenceInCalendarMonths(month, date) < 0 {
            return 0 // nothing due this month
        }
        let nextMonth = BudgetMonthMath.addMonths(month, 1)
        while date < nextMonth {
            toBudget += amount
            date = shift(date, numPeriods)
        }
        return toBudget
    }

    private func runSpend(_ template: GoalTemplate) -> Int {
        var fromMonth = template.from ?? ""
        var toMonth = template.month ?? ""
        var alreadyBudgeted = fromLastMonth
        var firstMonth = true

        let repeatInterval = template.annual == true
            ? (template.repeatCount ?? 1) * 12 : template.repeatCount
        var monthsAway = BudgetMonthMath.differenceInCalendarMonths(toMonth, month)
        if let repeatInterval, repeatInterval > 0, monthsAway < 0 {
            while monthsAway < 0 {
                toMonth = BudgetMonthMath.addMonths(toMonth, repeatInterval)
                fromMonth = BudgetMonthMath.addMonths(fromMonth, repeatInterval)
                monthsAway = BudgetMonthMath.differenceInCalendarMonths(toMonth, month)
            }
        }

        var walker = fromMonth
        while BudgetMonthMath.differenceInCalendarMonths(month, walker) > 0 {
            if firstMonth {
                let spent = sheet.spent(month: walker, category: category.id)
                let balance = sheet.leftover(month: walker, category: category.id)
                alreadyBudgeted = balance - spent
                firstMonth = false
            } else {
                alreadyBudgeted += sheet.budgeted(month: walker, category: category.id)
            }
            walker = BudgetMonthMath.addMonths(walker, 1)
        }

        let numMonths = BudgetMonthMath.differenceInCalendarMonths(toMonth, month)
        let target = BudgetMonthMath.amountToInteger(template.amount ?? 0)
        guard numMonths >= 0 else { return 0 }
        return BudgetMonthMath.jsRound(Double(target - alreadyBudgeted) / Double(numMonths + 1))
    }

    private func runPercentage(_ template: GoalTemplate, availableFunds: Int) throws -> Int {
        let percent = template.percent ?? 0
        let source = (template.category ?? "").lowercased()
        let sheetMonth = template.previous == true ? BudgetMonthMath.subMonths(month, 1) : month

        let monthlyIncome: Int
        if source == "all income" {
            monthlyIncome = sheet.totalIncome(month: sheetMonth)
        } else if source == "available funds" {
            monthlyIncome = availableFunds
        } else {
            guard let incomeCategory = allCategories.first(where: {
                $0.isIncome && ($0.id == template.category || $0.name.lowercased() == source)
            }) else {
                throw GoalTemplateError.category(
                    "Income category \"\(template.category ?? "")\" not found for percentage template")
            }
            monthlyIncome = sheet.spent(month: sheetMonth, category: incomeCategory.id)
        }
        return max(0, BudgetMonthMath.jsRound(Double(monthlyIncome) * percent / 100))
    }

    private func runAverage(_ template: GoalTemplate) -> Int {
        var average = Double(categoryAverage(maxMonths: template.numMonths ?? 0))
        // Sheet activity is cost (negative); budget the positive amount.
        if average < 0 { average *= -1 }

        if let adjustment = template.adjustment, let adjustmentType = template.adjustmentType {
            switch adjustmentType {
            case .percent:
                average *= 1 + adjustment / 100
            case .fixed:
                average += Double(BudgetMonthMath.amountToInteger(adjustment))
            }
        }
        return BudgetMonthMath.jsRound(average)
    }

    /// Port of `getCategoryAverage` + `getAverageMonths`: average the activity
    /// of up to `maxMonths` months ending the month before this one (never
    /// beyond last month of real time), stopping at the category's first
    /// month of activity.
    private func categoryAverage(maxMonths: Int) -> Int {
        var startMonth = BudgetMonthMath.prevMonth(month)
        if startMonth >= currentMonth {
            startMonth = BudgetMonthMath.prevMonth(currentMonth)
        }
        let firstActivity = sheet.firstActivityMonth[category.id]

        var months: [String] = []
        var walker = startMonth
        for _ in 0..<max(0, maxMonths) {
            if let firstActivity, BudgetMonthMath.monthInt(walker) < firstActivity { break }
            months.append(walker)
            walker = BudgetMonthMath.prevMonth(walker)
        }
        guard !months.isEmpty else { return 0 }

        let sum = months.reduce(0) { $0 + sheet.spent(month: $1, category: category.id) }
        return BudgetMonthMath.jsRound(Double(sum) / Double(months.count))
    }

    private func runBy() -> (toBudget: Int, perTemplateNeed: [Int: Int]) {
        let byTemplates = templates.filter { $0.template.type == .by }
        var savedInfo: [(numMonths: Int, period: Int?)] = []
        var shortestMonths: Int?

        for (_, template) in byTemplates {
            var targetMonth = template.month ?? ""
            let period: Int? = template.annual == true
                ? (template.repeatCount ?? 1) * 12
                : template.repeatCount
            var numMonths = BudgetMonthMath.differenceInCalendarMonths(targetMonth, month)
            if let period, period > 0 {
                while numMonths < 0 {
                    targetMonth = BudgetMonthMath.addMonths(targetMonth, period)
                    numMonths = BudgetMonthMath.differenceInCalendarMonths(targetMonth, month)
                }
            }
            savedInfo.append((numMonths, period))
            if shortestMonths == nil || numMonths < shortestMonths! {
                shortestMonths = numMonths
            }
        }

        let shortNumMonths = shortestMonths ?? 0
        var totalNeeded = 0
        var perTemplateNeed: [Int: Int] = [:]
        for (position, entry) in byTemplates.enumerated() {
            let (numMonths, period) = savedInfo[position]
            let target = BudgetMonthMath.amountToInteger(entry.template.amount ?? 0)
            let amount: Int
            if numMonths > shortNumMonths, let period, period > 0 {
                // Back-interpolate what the longer-window template needs
                // during the short window.
                amount = BudgetMonthMath.jsRound(
                    Double(target) / Double(period) * Double(period - numMonths + shortNumMonths))
            } else if numMonths > shortNumMonths {
                amount = BudgetMonthMath.jsRound(
                    Double(target) / Double(numMonths + 1) * Double(shortNumMonths + 1))
            } else {
                amount = target
            }
            perTemplateNeed[entry.index] = amount
            totalNeeded += amount
        }
        let toBudget = BudgetMonthMath.jsRound(
            Double(totalNeeded - fromLastMonth) / Double(shortNumMonths + 1))
        return (toBudget, perTemplateNeed)
    }
}

// MARK: - Orchestration

/// Port of loot-core `goal-template.ts` `computeTemplates`/`processTemplate`:
/// run every category's templates for one month and produce the budget and
/// goal writes.
enum GoalTemplateEngine {

    struct GoalWrite: Equatable, Sendable {
        let category: String
        let goal: Int?
        let longGoal: Bool
    }

    struct BudgetWrite: Equatable, Sendable {
        let category: String
        let amount: Int
    }

    enum RunResult: Equatable, Sendable {
        case upToDate(goalResets: [GoalWrite])
        case applied(count: Int, budgets: [BudgetWrite], goals: [GoalWrite])
        case errors([String])
    }

    static func distributeRemainder(
        contexts: [GoalTemplateContext],
        availBudget: Int
    ) -> Int {
        var availBudget = availBudget
        var remainderContexts = contexts.filter { $0.hasRemainder() }
        while availBudget > 0, !remainderContexts.isEmpty {
            let remainderWeight = remainderContexts.reduce(0.0) { $0 + $1.getRemainderWeight() }
            let perWeight = Double(availBudget) / remainderWeight
            let beforePass = availBudget
            for context in remainderContexts {
                availBudget -= context.runRemainder(budgetAvail: availBudget, perWeight: perWeight)
            }
            if availBudget == beforePass { break }
            remainderContexts = contexts.filter { $0.hasRemainder() }
        }
        return availBudget
    }

    /// - Parameters:
    ///   - categories: the categories to process (already filtered the way the
    ///     caller wants: month-apply passes visible categories — income only on
    ///     tracking budgets — while single-category apply passes just that one).
    ///   - allCategories: every live category, for percentage source lookups.
    static func run(
        month: String,
        force: Bool,
        categoryTemplates: [String: [GoalTemplate]],
        categories: [GoalTemplateCategory],
        allCategories: [GoalTemplateCategory],
        schedules: [GoalScheduleInfo],
        sheet: GoalTemplateSheet,
        currentMonth: String = BudgetMonthMath.currentMonth()
    ) -> RunResult {
        var contexts: [GoalTemplateContext] = []
        var availBudget = sheet.availableStart
        var prioritySet: Set<Int> = []
        var errors: [String] = []
        var orphanGoals: [GoalWrite] = []
        let monthInt = BudgetMonthMath.monthInt(month)

        for category in categories {
            let templates = categoryTemplates[category.id]
            let budgeted = sheet.budgeted(month: month, category: category.id)

            if let templates, budgeted == 0 || force {
                do {
                    let context = try GoalTemplateContext(
                        templates: templates,
                        category: category,
                        month: month,
                        budgeted: budgeted,
                        sheet: sheet,
                        schedules: schedules,
                        allCategories: allCategories,
                        currentMonth: currentMonth)
                    // Funds not managed by templates stay out of the pool.
                    if !context.isGoalOnly() {
                        availBudget += budgeted
                    }
                    availBudget += context.limitExcess
                    context.getPriorities().forEach { prioritySet.insert($0) }
                    contexts.append(context)
                } catch GoalTemplateError.category(let message) {
                    errors.append("\(category.name): \(message)")
                } catch {
                    errors.append("\(category.name): \(error.localizedDescription)")
                }
            } else if templates == nil {
                // Orphaned goal: the templates were removed, so clear the
                // stored goal. ponytail: upstream emits this reset for every
                // template-less category on every apply; writing only where a
                // goal value actually exists converges to the same state
                // without the message churn.
                if sheet.goalRows.contains(.init(monthInt, category.id)) {
                    orphanGoals.append(GoalWrite(category: category.id, goal: nil, longGoal: false))
                }
            }
        }

        if !errors.isEmpty {
            return .errors(errors)
        }

        // Run each priority level across every category before moving on.
        for priority in prioritySet.sorted() {
            let availStart = availBudget
            for context in contexts {
                do {
                    let budget = try context.runTemplatesForPriority(
                        priority, budgetAvail: availBudget, availStart: availStart)
                    availBudget -= budget
                } catch GoalTemplateError.category(let message) {
                    errors.append("\(context.category.name): \(message)")
                } catch {
                    errors.append("\(context.category.name): \(error.localizedDescription)")
                }
            }
            if !errors.isEmpty { return .errors(errors) }
        }

        _ = distributeRemainder(contexts: contexts, availBudget: availBudget)

        if contexts.isEmpty {
            return .upToDate(goalResets: orphanGoals)
        }

        var budgets: [BudgetWrite] = []
        var goals = orphanGoals
        for context in contexts {
            let values = context.getValues()
            budgets.append(BudgetWrite(category: context.category.id, amount: values.budgeted))
            goals.append(GoalWrite(
                category: context.category.id,
                goal: values.goal,
                longGoal: values.longGoal == true))
        }
        return .applied(count: contexts.count, budgets: budgets, goals: goals)
    }

    /// Port of upstream `dryRunCategoryTemplate`: how much would these
    /// templates budget for one category this month, and how much does each
    /// template contribute? Skips the available-funds clamp so future months
    /// (where To Budget is empty) show the templates' intended amounts.
    /// Validation errors return zeros, matching upstream.
    static func dryRun(
        month: String,
        category: GoalTemplateCategory,
        templates: [GoalTemplate],
        allCategories: [GoalTemplateCategory],
        schedules: [GoalScheduleInfo],
        sheet: GoalTemplateSheet,
        currentMonth: String = BudgetMonthMath.currentMonth()
    ) -> (budgeted: Int, perTemplate: [Int]) {
        let zeros = [Int](repeating: 0, count: templates.count)
        guard !templates.isEmpty else { return (0, zeros) }
        do {
            let budgeted = sheet.budgeted(month: month, category: category.id)
            let context = try GoalTemplateContext(
                templates: templates,
                category: category,
                month: month,
                budgeted: budgeted,
                sheet: sheet,
                schedules: schedules,
                allCategories: allCategories,
                currentMonth: currentMonth,
                skipAvailableClamp: true)
            var availBudget = sheet.availableStart
            if !context.isGoalOnly() { availBudget += budgeted }
            availBudget += context.limitExcess
            for priority in context.getPriorities().sorted() {
                let availStart = availBudget
                let budget = try context.runTemplatesForPriority(
                    priority, budgetAvail: availBudget, availStart: availStart)
                availBudget -= budget
            }
            _ = distributeRemainder(contexts: [context], availBudget: availBudget)
            let values = context.getValues()
            return (values.budgeted, values.perTemplate)
        } catch {
            return (0, zeros)
        }
    }
}
