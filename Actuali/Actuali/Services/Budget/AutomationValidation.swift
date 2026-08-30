import Foundation

/// Per-automation and cross-automation validation — port of the web's
/// `validateAutomation.ts`. Errors block saving, exactly as on the web.
enum AutomationError: Equatable, Sendable {
    case scheduleNotFound(name: String)
    case refillNoCap
    case limitNoContributor
    case percentageOutOfRange(percent: Double)
    case percentageNoSource
    case percentageSourceNotFound(source: String)
    case byNoMonth
    case byTargetPast(month: String)
    case spendNoFrom
    case spendFromAfterTarget
    case adjustmentOutOfRange

    var title: String {
        switch self {
        case .scheduleNotFound: "Schedule not found"
        case .refillNoCap: "Refill needs a balance cap"
        case .limitNoContributor: "Balance cap needs a contributing automation"
        case .percentageOutOfRange: "Percentage out of range"
        case .percentageNoSource: "Source category missing"
        case .percentageSourceNotFound: "Source category not recognised"
        case .byNoMonth: "Target month missing"
        case .byTargetPast: "Target is in the past"
        case .spendNoFrom: "Early-spending month missing"
        case .spendFromAfterTarget: "Early spending starts after target"
        case .adjustmentOutOfRange: "Adjustment out of range"
        }
    }

    var shortMessage: String {
        switch self {
        case .scheduleNotFound(let name):
            name.isEmpty ? "Pick a schedule" : "No schedule named “\(name)”"
        case .refillNoCap: "Add a balance cap"
        case .limitNoContributor: "Add an automation that contributes funds"
        case .percentageOutOfRange(let percent):
            "\(AutomationSentences.trimTrailingZeros(percent))% must be between 0 and 100"
        case .percentageNoSource: "Pick a source category"
        case .percentageSourceNotFound: "Pick a valid income category"
        case .byNoMonth: "Pick a target month"
        case .byTargetPast(let month):
            "\(AutomationSentences.monthLabel(month)) has already passed"
        case .spendNoFrom: "Pick an early-spending start month"
        case .spendFromAfterTarget: "Early spending must start before the target"
        case .adjustmentOutOfRange: "Adjustment out of range"
        }
    }

    var detail: String {
        switch self {
        case .scheduleNotFound:
            "Pick an existing schedule, or create one in Schedules. This automation can't run until it's linked to a schedule."
        case .refillNoCap:
            "Refill automations must have a “Balance cap” automation added to use as the target."
        case .limitNoContributor:
            "A balance cap on its own does nothing. Add a contributing automation (such as a fixed amount, save by date, or whatever is left) so the cap has something to clamp."
        case .percentageOutOfRange:
            "Set a value greater than 0% and at most 100%."
        case .percentageNoSource:
            "Pick which income the percentage is taken from."
        case .percentageSourceNotFound:
            "The source must be an income category, total income, or available funds."
        case .byNoMonth:
            "Pick the month the target amount should be saved by."
        case .byTargetPast:
            "One-shot targets must be in the future. Turn on Repeats to roll a past anchor forward."
        case .spendNoFrom:
            "Pick the month spending is expected to start."
        case .spendFromAfterTarget:
            "The early-spending month must be on or before the target month."
        case .adjustmentOutOfRange:
            "Percentage adjustments must be between -100% and 1000%."
        }
    }
}

enum AutomationConflict: Equatable, Sendable {
    case percentOver100(total: Double)
    case schedulePriorityMismatch

    var message: String {
        switch self {
        case .percentOver100(let total):
            "Percentage automations for one source add up to \(AutomationSentences.trimTrailingZeros(total))%. Together they must stay at or below 100%."
        case .schedulePriorityMismatch:
            "Schedule and save-by-date automations must all share one priority, or none of them will budget."
        }
    }
}

enum AutomationValidation {

    private static func adjustmentOutOfRange(_ template: GoalTemplate) -> Bool {
        guard template.type == .schedule || template.type == .average,
              let adjustment = template.adjustment,
              template.adjustmentType == .percent else { return false }
        return adjustment <= -100 || adjustment > 1000
    }

    /// - Parameter validPercentageSources: income category ids, lower-cased
    ///   names, and the special aliases ("all income", "available funds").
    static func validate(
        entry: AutomationEntry,
        allTemplates: [GoalTemplate],
        schedules: [GoalScheduleInfo],
        currentMonth: String,
        validPercentageSources: Set<String>
    ) -> AutomationError? {
        let template = entry.template
        switch entry.displayType {
        case .schedule:
            guard template.type == .schedule else { return nil }
            if (template.scheduleId ?? "").isEmpty, (template.name ?? "").isEmpty {
                return .scheduleNotFound(name: "")
            }
            let match = schedules.first {
                template.scheduleId != nil
                    ? $0.id == template.scheduleId : $0.name == template.name
            }
            if match == nil || match?.completed == true {
                return .scheduleNotFound(name: template.name ?? "")
            }
            if adjustmentOutOfRange(template) { return .adjustmentOutOfRange }
            return nil

        case .historical:
            return adjustmentOutOfRange(template) ? .adjustmentOutOfRange : nil

        case .refill:
            return allTemplates.contains { $0.type == .limit } ? nil : .refillNoCap

        case .limit:
            let hasContributor = allTemplates.contains {
                $0.type != .limit && $0.type != .goal && $0.type != .error
            }
            return hasContributor ? nil : .limitNoContributor

        case .percentage:
            guard template.type == .percentage else { return nil }
            guard let source = template.category, !source.isEmpty else {
                return .percentageNoSource
            }
            let percent = template.percent ?? 0
            if percent <= 0 || percent > 100 {
                return .percentageOutOfRange(percent: percent)
            }
            if !validPercentageSources.contains(source),
               !validPercentageSources.contains(source.lowercased()) {
                return .percentageSourceNotFound(source: source)
            }
            return nil

        case .by:
            guard template.type == .by || template.type == .spend else { return nil }
            guard let month = template.month, BudgetMonthMath.yearAndMonth(month) != nil else {
                return .byNoMonth
            }
            let monthsRemaining = BudgetMonthMath.differenceInCalendarMonths(month, currentMonth)
            // Recurring targets anchored in the past roll forward; only flag
            // one-shot goals.
            if monthsRemaining < 0, template.annual != true, template.repeatCount == nil {
                return .byTargetPast(month: month)
            }
            if template.type == .spend {
                guard let from = template.from, BudgetMonthMath.yearAndMonth(from) != nil else {
                    return .spendNoFrom
                }
                if BudgetMonthMath.differenceInCalendarMonths(month, from) < 0 {
                    return .spendFromAfterTarget
                }
            }
            return nil

        case .fixed, .remainder, .goal:
            return nil
        }
    }

    /// Sum of percentage templates per (previous, source) must stay ≤ 100.
    static func percentageAllocationConflict(_ templates: [GoalTemplate]) -> AutomationConflict? {
        var percentBySource: [String: Double] = [:]
        for template in templates where template.type == .percentage {
            guard let source = template.category, !source.isEmpty else { continue }
            let key = "\(template.previous == true)|\(source.lowercased())"
            percentBySource[key, default: 0] += template.percent ?? 0
        }
        let maxPercent = percentBySource.values.max() ?? 0
        return maxPercent > 100 ? .percentOver100(total: maxPercent) : nil
    }

    /// The engine requires every schedule and by template in a category to
    /// share one priority; a mismatch means none of them budget.
    static func schedulePriorityConflict(_ templates: [GoalTemplate]) -> AutomationConflict? {
        var priorities: Set<Int> = []
        for template in templates where template.type == .schedule || template.type == .by {
            priorities.insert(template.priority ?? 0)
        }
        return priorities.count > 1 ? .schedulePriorityMismatch : nil
    }
}
