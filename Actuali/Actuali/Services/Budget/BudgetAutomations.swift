import Foundation

/// The automation editor's grouping of template types — port of the web's
/// `DisplayTemplateType` (goals/constants.ts). One display type can cover
/// several storage types (historical = average/copy, by = by/spend, fixed =
/// periodic, absorbing legacy simple).
enum AutomationDisplayType: String, CaseIterable, Identifiable, Sendable {
    case fixed, schedule, by, percentage, historical, limit, refill, remainder, goal

    var id: String { rawValue }

    /// Types managed in the Options section rather than as contributions.
    static let nonContribution: Set<AutomationDisplayType> = [.limit, .goal]
    /// At most one of each of these per category (web's SINGLETON_TYPES,
    /// plus goal which the editor also adds through a dedicated button).
    static let singleton: Set<AutomationDisplayType> = [.limit, .refill, .remainder, .goal]

    var label: String {
        switch self {
        case .fixed: "Fixed amount"
        case .schedule: "Cover schedule"
        case .by: "Save by date"
        case .percentage: "% of income"
        case .historical: "From history"
        case .limit: "Balance cap"
        case .refill: "Refill to cap"
        case .remainder: "Whatever is left"
        case .goal: "Long-term goal"
        }
    }

    var explanation: String {
        switch self {
        case .fixed: "Add a set amount every month, week, day, or year."
        case .schedule: "Save up for a scheduled transaction."
        case .by: "Spread a target amount across the months until a deadline."
        case .percentage: "A share of this month's or last month's income."
        case .historical: "Use past months: average, a specific month, or a copy."
        case .limit: "Stop budgeting to this category once the balance reaches a cap."
        case .refill: "Top the category back up to the balance cap each month."
        case .remainder: "Split any remaining To Budget across these categories."
        case .goal: "Set a long-term savings target. This changes the coloring of the balance on the budget page to be based on progress towards the target rather than the current month funding progress."
        }
    }

    var systemImage: String {
        switch self {
        case .fixed: "banknote"
        case .schedule: "calendar"
        case .by: "target"
        case .percentage: "percent"
        case .historical: "clock.arrow.circlepath"
        case .limit: "equal.circle"
        case .refill: "arrow.triangle.2.circlepath"
        case .remainder: "square.split.2x2"
        case .goal: "flag"
        }
    }

    /// Which display type edits a stored template — port of the web's
    /// `getDisplayTypeFromTemplate`; nil for error templates.
    static func forTemplate(_ template: GoalTemplate) -> AutomationDisplayType? {
        switch template.type {
        case .percentage: .percentage
        case .schedule: .schedule
        case .periodic, .simple: .fixed
        case .limit: .limit
        case .refill: .refill
        case .average, .copy: .historical
        case .by, .spend: .by
        case .remainder: .remainder
        case .goal: .goal
        case .error: nil
        }
    }
}

/// One editable automation row — the web's `AutomationEntry`.
struct AutomationEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var template: GoalTemplate
    var displayType: AutomationDisplayType

    init(template: GoalTemplate, displayType: AutomationDisplayType) {
        id = UUID()
        self.template = template
        self.displayType = displayType
    }
}

enum BudgetAutomations {
    /// The web reducer's DEFAULT_PRIORITY for new automations.
    static let defaultPriority = 1

    // MARK: - Defaults (port of reducer.ts changeType / automationExamples)

    static func defaultTemplate(
        for displayType: AutomationDisplayType,
        currentMonth: String = BudgetMonthMath.currentMonth()
    ) -> GoalTemplate {
        switch displayType {
        case .fixed:
            var template = GoalTemplate(type: .periodic, directive: .template, priority: defaultPriority)
            template.amount = 100
            template.period = .init(period: .month, amount: 1)
            template.starting = BudgetMonthMath.firstDayOfMonth(currentMonth)
            return template
        case .by:
            var template = GoalTemplate(type: .by, directive: .template, priority: defaultPriority)
            template.amount = 1200
            // 12 months out so late-year users don't get a passed target.
            template.month = BudgetMonthMath.addMonths(currentMonth, 12)
            template.annual = true
            template.repeatCount = 1
            return template
        case .schedule:
            var template = GoalTemplate(type: .schedule, directive: .template, priority: defaultPriority)
            template.name = ""
            return template
        case .percentage:
            var template = GoalTemplate(type: .percentage, directive: .template, priority: defaultPriority)
            template.percent = 15
            template.previous = false
            template.category = "all income"
            return template
        case .historical:
            var template = GoalTemplate(type: .average, directive: .template, priority: defaultPriority)
            template.numMonths = 3
            return template
        case .limit:
            var template = GoalTemplate(type: .limit, directive: .template, priority: nil)
            template.limit = .init(amount: 500, hold: false, period: .monthly, start: nil)
            template.amount = 500
            return template
        case .refill:
            return GoalTemplate(type: .refill, directive: .template, priority: defaultPriority)
        case .remainder:
            var template = GoalTemplate(type: .remainder, directive: .template, priority: nil)
            template.weight = 1
            return template
        case .goal:
            var template = GoalTemplate(type: .goal, directive: .goal, priority: nil)
            template.amount = 1000
            return template
        }
    }

    /// Change an entry to another display type, keeping the description and
    /// resetting the rest to that type's defaults (matching the web reducer,
    /// which discards field state on a type switch).
    static func convert(
        _ entry: AutomationEntry,
        to displayType: AutomationDisplayType,
        currentMonth: String = BudgetMonthMath.currentMonth()
    ) -> AutomationEntry {
        guard entry.displayType != displayType else { return entry }
        var next = entry
        var template = defaultTemplate(for: displayType, currentMonth: currentMonth)
        template.description = entry.template.description
        next.template = template
        next.displayType = displayType
        return next
    }

    /// Toggle a by template's early-spending mode (by ↔ spend), carrying the
    /// shared fields — port of the reducer's mapTemplateTypesForUpdate.
    static func setEarlySpending(_ template: GoalTemplate, enabled: Bool) -> GoalTemplate {
        var next = template
        if enabled, template.type == .by {
            next.type = .spend
            next.from = template.from ?? template.month
        } else if !enabled, template.type == .spend {
            next.type = .by
            next.from = nil
        }
        return next
    }

    /// Toggle a historical template's mode (average ↔ copy), carrying the
    /// month count across.
    static func setHistoricalMode(_ template: GoalTemplate, copyMode: Bool) -> GoalTemplate {
        var next = template
        if copyMode, template.type == .average {
            next.type = .copy
            next.lookBack = template.numMonths
            next.numMonths = nil
            next.adjustment = nil
            next.adjustmentType = nil
        } else if !copyMode, template.type == .copy {
            next.type = .average
            next.numMonths = template.lookBack
            next.lookBack = nil
        }
        return next
    }

    // MARK: - Migration (port of migrateTemplatesToAutomations.ts)

    /// Turn stored/parsed templates into editor entries: legacy `simple`
    /// templates split into limit (+refill for limit-only) and periodic
    /// parts; attached limits on periodic/remainder split out; schedule
    /// templates hydrated with the schedule id.
    static func migrateToEntries(
        _ templates: [GoalTemplate],
        schedules: [GoalScheduleInfo]
    ) -> [AutomationEntry] {
        var entries: [AutomationEntry] = []

        func limitEntry(_ limit: GoalTemplate.Limit, description: String? = nil) -> AutomationEntry {
            var template = GoalTemplate(type: .limit, directive: .template, priority: nil)
            template.limit = limit
            template.amount = limit.amount
            template.description = description
            return AutomationEntry(template: template, displayType: .limit)
        }

        for template in templates {
            switch template.type {
            case .schedule:
                var hydrated = template
                let schedule = template.scheduleId.flatMap { id in
                    schedules.first { $0.id == id }
                } ?? template.name.flatMap { name in
                    schedules.first {
                        $0.name?.trimmingCharacters(in: .whitespaces)
                            == name.trimmingCharacters(in: .whitespaces)
                    }
                }
                if let schedule {
                    hydrated.scheduleId = schedule.id
                    hydrated.name = schedule.name ?? template.name
                }
                entries.append(AutomationEntry(template: hydrated, displayType: .schedule))

            case .simple:
                let monthly = template.monthly
                let hasMonthly = monthly != nil && monthly != 0
                if let limit = template.limit {
                    // A description on a limit-only simple template belongs
                    // to the limit; with a monthly amount it goes there.
                    entries.append(limitEntry(
                        limit, description: hasMonthly ? nil : template.description))
                    if monthly == nil {
                        let refill = GoalTemplate(
                            type: .refill, directive: .template, priority: template.priority)
                        entries.append(AutomationEntry(template: refill, displayType: .refill))
                    }
                }
                let contribution: Double? = hasMonthly
                    ? monthly : (monthly == 0 && template.limit == nil ? 0 : nil)
                if let contribution {
                    var periodic = GoalTemplate(
                        type: .periodic, directive: .template, priority: template.priority)
                    periodic.amount = contribution
                    periodic.period = .init(period: .month, amount: 1)
                    periodic.starting = BudgetMonthMath.firstDayOfMonth(
                        BudgetMonthMath.currentMonth())
                    periodic.description = template.description
                    entries.append(AutomationEntry(template: periodic, displayType: .fixed))
                }
                // A simple with neither monthly nor limit is a no-op; drop it.

            case .periodic, .remainder:
                if let limit = template.limit {
                    var base = template
                    base.limit = nil
                    if let displayType = AutomationDisplayType.forTemplate(base) {
                        entries.append(AutomationEntry(template: base, displayType: displayType))
                    }
                    entries.append(limitEntry(limit))
                } else if let displayType = AutomationDisplayType.forTemplate(template) {
                    entries.append(AutomationEntry(template: template, displayType: displayType))
                }

            default:
                if let displayType = AutomationDisplayType.forTemplate(template) {
                    entries.append(AutomationEntry(template: template, displayType: displayType))
                }
            }
        }
        return entries
    }
}
