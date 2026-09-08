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

    var title: String { title(locale: .autoupdatingCurrent, bundle: .main) }

    func title(locale: Locale, bundle: Bundle) -> String {
        switch self {
        case .scheduleNotFound: String(localized: "Schedule not found", bundle: bundle, locale: locale)
        case .refillNoCap: String(localized: "Refill needs a balance cap", bundle: bundle, locale: locale)
        case .limitNoContributor: String(localized: "Balance cap needs a contributing automation", bundle: bundle, locale: locale)
        case .percentageOutOfRange: String(localized: "Percentage out of range", bundle: bundle, locale: locale)
        case .percentageNoSource: String(localized: "Source category missing", bundle: bundle, locale: locale)
        case .percentageSourceNotFound: String(localized: "Source category not recognised", bundle: bundle, locale: locale)
        case .byNoMonth: String(localized: "Target month missing", bundle: bundle, locale: locale)
        case .byTargetPast: String(localized: "Target is in the past", bundle: bundle, locale: locale)
        case .spendNoFrom: String(localized: "Early-spending month missing", bundle: bundle, locale: locale)
        case .spendFromAfterTarget: String(localized: "Early spending starts after target", bundle: bundle, locale: locale)
        case .adjustmentOutOfRange: String(localized: "Adjustment out of range", bundle: bundle, locale: locale)
        }
    }

    var shortMessage: String { shortMessage(locale: .autoupdatingCurrent, bundle: .main) }

    func shortMessage(locale: Locale, bundle: Bundle) -> String {
        switch self {
        case .scheduleNotFound(let name):
            name.isEmpty
                ? String(localized: "Pick a schedule", bundle: bundle, locale: locale)
                : String(format: String(localized: "No schedule named “%@”", bundle: bundle, locale: locale), name)
            case .refillNoCap: String(localized: "Add a balance cap", bundle: bundle, locale: locale)
            case .limitNoContributor: String(localized: "Add an automation that contributes funds", bundle: bundle, locale: locale)
        case .percentageOutOfRange(let percent):
            String(format: String(localized: "%@ must be between 0 and 100", bundle: bundle, locale: locale), "\(AutomationSentences.trimTrailingZeros(percent))%")
        case .percentageNoSource: String(localized: "Pick a source category", bundle: bundle, locale: locale)
        case .percentageSourceNotFound: String(localized: "Pick a valid income category", bundle: bundle, locale: locale)
        case .byNoMonth: String(localized: "Pick a target month", bundle: bundle, locale: locale)
        case .byTargetPast(let month):
            String(format: String(localized: "%@ has already passed", bundle: bundle, locale: locale), AutomationSentences.monthLabel(month))
        case .spendNoFrom: String(localized: "Pick an early-spending start month", bundle: bundle, locale: locale)
        case .spendFromAfterTarget: String(localized: "Early spending must start before the target", bundle: bundle, locale: locale)
        case .adjustmentOutOfRange: String(localized: "Adjustment out of range", bundle: bundle, locale: locale)
        }
    }

    var detail: String { detail(locale: .autoupdatingCurrent, bundle: .main) }

    func detail(locale: Locale, bundle: Bundle) -> String {
        switch self {
        case .scheduleNotFound:
            String(localized: "Pick an existing schedule, or create one in Schedules. This automation can't run until it's linked to a schedule.", bundle: bundle, locale: locale)
        case .refillNoCap:
            String(localized: "Refill automations must have a “Balance cap” automation added to use as the target.", bundle: bundle, locale: locale)
        case .limitNoContributor:
            String(localized: "A balance cap on its own does nothing. Add a contributing automation (such as a fixed amount, save by date, or whatever is left) so the cap has something to clamp.", bundle: bundle, locale: locale)
        case .percentageOutOfRange:
            String(localized: "Set a value greater than 0% and at most 100%.", bundle: bundle, locale: locale)
        case .percentageNoSource:
            String(localized: "Pick which income the percentage is taken from.", bundle: bundle, locale: locale)
        case .percentageSourceNotFound:
            String(localized: "The source must be an income category, total income, or available funds.", bundle: bundle, locale: locale)
        case .byNoMonth:
            String(localized: "Pick the month the target amount should be saved by.", bundle: bundle, locale: locale)
        case .byTargetPast:
            String(localized: "One-shot targets must be in the future. Turn on Repeats to roll a past anchor forward.", bundle: bundle, locale: locale)
        case .spendNoFrom:
            String(localized: "Pick the month spending is expected to start.", bundle: bundle, locale: locale)
        case .spendFromAfterTarget:
            String(localized: "The early-spending month must be on or before the target month.", bundle: bundle, locale: locale)
        case .adjustmentOutOfRange:
            String(localized: "Percentage adjustments must be between -100% and 1000%.", bundle: bundle, locale: locale)
        }
    }
}

enum AutomationConflict: Equatable, Sendable {
    case percentOver100(total: Double)
    case schedulePriorityMismatch

    var message: String { message(locale: .autoupdatingCurrent, bundle: .main) }

    func message(locale: Locale, bundle: Bundle) -> String {
        switch self {
        case .percentOver100(let total):
            String(format: String(localized: "Percentage automations for one source add up to %@. Together they must stay at or below 100%.", bundle: bundle, locale: locale), "\(AutomationSentences.trimTrailingZeros(total))%")
        case .schedulePriorityMismatch:
            String(localized: "Schedule and save-by-date automations must all share one priority, or none of them will budget.", bundle: bundle, locale: locale)
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
