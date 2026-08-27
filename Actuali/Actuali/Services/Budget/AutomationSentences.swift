import Foundation

/// Human-readable one-line summaries of templates (port of the web's
/// TemplateSentence / *ReadOnly components) and the template → `#template`
/// note-line renderer (port of template-notes.ts `unparse`) used by the
/// un-migrate flow.
enum AutomationSentences {

    static func trimTrailingZeros(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// "MMM yyyy" for a YYYY-MM string, "—" when empty (web formatMonthLabel).
    static func monthLabel(_ month: String?) -> String {
        guard let month, !month.isEmpty else { return "—" }
        guard let (year, monthNumber) = BudgetMonthMath.yearAndMonth(month) else { return month }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        let components = DateComponents(year: year, month: monthNumber, day: 1)
        guard let date = Calendar.current.date(from: components) else { return month }
        return formatter.string(from: date)
    }

    private static func plural(_ count: Int, _ singular: String, _ pluralForm: String) -> String {
        count == 1 ? singular : pluralForm
    }

    private static func adjustmentSuffix(_ template: GoalTemplate, amount: (Double) -> String) -> String {
        guard let adjustment = template.adjustment, let type = template.adjustmentType else {
            return ""
        }
        let direction = adjustment >= 0 ? "increased" : "decreased"
        let value = abs(adjustment)
        let formatted = type == .percent
            ? "\(trimTrailingZeros(value))%" : amount(value)
        return ", \(direction) by \(formatted)"
    }

    /// The list row / tooltip sentence for one template. `amount` formats a
    /// whole-currency-unit value for display; `categoryName` resolves income
    /// category ids for percentage sources.
    static func sentence(
        for template: GoalTemplate,
        amount: (Double) -> String,
        categoryName: (String) -> String?
    ) -> String {
        switch template.type {
        case .periodic:
            let value = amount(template.amount ?? 0)
            let count = template.period?.amount ?? 1
            let unit = template.period?.period ?? .month
            let unitName: String
            switch unit {
            case .day: unitName = plural(count, "day", "days")
            case .week: unitName = plural(count, "week", "weeks")
            case .month: unitName = plural(count, "month", "months")
            case .year: unitName = plural(count, "year", "years")
            }
            return count == 1
                ? "Budget \(value) every \(unitName)"
                : "Budget \(value) every \(count) \(unitName)"

        case .by, .spend:
            let value = amount(template.amount ?? 0)
            let month = monthLabel(template.month)
            var sentence = "Save \(value) by \(month)"
            if template.type == .spend {
                sentence += ", early spending from \(monthLabel(template.from))"
            }
            if template.annual == true {
                let repeats = template.repeatCount ?? 1
                sentence += ", repeating every \(repeats == 1 ? "year" : "\(repeats) years")"
            } else if let repeats = template.repeatCount, repeats > 0 {
                sentence += ", repeating every \(repeats == 1 ? "month" : "\(repeats) months")"
            }
            return sentence

        case .schedule:
            guard let name = template.name, !name.isEmpty else {
                return "Budget for a schedule"
            }
            let base = template.full == true
                ? "Cover the occurrences of the schedule ‘\(name)’ this month"
                : "Save up for the schedule ‘\(name)’"
            return base + adjustmentSuffix(template, amount: amount)

        case .percentage:
            let percent = trimTrailingZeros(template.percent ?? 0)
            let when = template.previous == true ? "last month" : "this month"
            let source = template.category ?? ""
            switch source.lowercased() {
            case "all income":
                return "Budget \(percent)% of total income \(when)"
            case "available funds":
                return "Budget \(percent)% of available funds to budget \(when)"
            default:
                let name = categoryName(source) ?? source
                return "Budget \(percent)% of ‘\(name)’ \(when)"
            }

        case .copy:
            let lookBack = template.lookBack ?? 0
            return "Budget the same amount as \(lookBack) \(plural(lookBack, "month", "months")) ago"

        case .average:
            let months = template.numMonths ?? 0
            let base = "Budget the average of the last \(months) complete \(plural(months, "month", "months"))"
            return base + adjustmentSuffix(template, amount: amount)

        case .remainder:
            return "Share remaining funds to budget (weight \(trimTrailingZeros(template.weight ?? 1)))"

        case .goal:
            return "Long-term goal of \(amount(template.amount ?? 0))"

        case .refill:
            return "Refill to balance limit"

        case .limit:
            guard let limit = template.limit else { return "Set a balance limit" }
            let value = amount(limit.amount)
            let cap = limit.hold ? "soft cap" : "hard cap"
            switch limit.period {
            case .daily: return "Set a balance limit of \(value)/day (\(cap))"
            case .weekly: return "Set a balance limit of \(value)/week (\(cap))"
            case .monthly: return "Set a balance limit of \(value)/month (\(cap))"
            }

        case .simple, .error:
            return "Unsupported template type: \(template.type.rawValue)"
        }
    }

    // MARK: - Note rendering (port of template-notes.ts unparse)

    private static func prefix(forPriority priority: Int?) -> String {
        // Priority 0 is the parser's "unset" default and drops the suffix.
        guard let priority, priority != 0 else { return "#template" }
        return "#template-\(priority)"
    }

    private static func limitToString(_ limit: GoalTemplate.Limit) -> String {
        let base: String
        switch limit.period {
        case .weekly:
            base = "up to \(trimTrailingZeros(limit.amount)) per week starting \(limit.start ?? "")"
        case .daily:
            base = "up to \(trimTrailingZeros(limit.amount)) per day"
        case .monthly:
            base = "up to \(trimTrailingZeros(limit.amount))"
        }
        return limit.hold ? "\(base) hold" : base
    }

    private static func adjustmentToString(_ template: GoalTemplate) -> String {
        guard let adjustment = template.adjustment else { return "" }
        let op = adjustment >= 0 ? "increase" : "decrease"
        let suffix = template.adjustmentType == .percent ? "%" : ""
        return " [\(op) \(trimTrailingZeros(abs(adjustment)))\(suffix)]"
    }

    private static func repeatToString(annual: Bool?, repeatCount: Int?) -> String? {
        guard let annual else { return nil }
        if annual {
            guard let repeatCount, repeatCount != 1 else { return "year" }
            return "\(repeatCount) years"
        }
        guard let repeatCount, repeatCount != 1 else { return "month" }
        return "\(repeatCount) months"
    }

    /// Render one template as a `#template`/`#goal` note line; nil for
    /// error templates and a standalone refill (which merges into the limit).
    static func noteLine(
        for template: GoalTemplate,
        refill: GoalTemplate?,
        categoryName: (String) -> String?
    ) -> String? {
        let prefix = prefix(forPriority: template.priority)
        switch template.type {
        case .goal:
            return "#goal \(trimTrailingZeros(template.amount ?? 0))"
        case .simple:
            var line = prefix
            if let monthly = template.monthly { line += " \(trimTrailingZeros(monthly))" }
            if let limit = template.limit { line += " \(limitToString(limit))" }
            return line
        case .schedule:
            var line = "\(prefix) schedule"
            if template.full == true { line += " full" }
            line += " \(template.name ?? "")"
            line += adjustmentToString(template)
            return line
        case .percentage:
            let previous = template.previous == true ? "previous " : ""
            // The UI stores income category ids; note grammar wants names.
            let source = template.category.map { categoryName($0) ?? $0 } ?? ""
            return "\(prefix) \(trimTrailingZeros(template.percent ?? 0))% of \(previous)\(source)"
        case .periodic:
            let period = template.period ?? .init(period: .month, amount: 1)
            var line = "\(prefix) \(trimTrailingZeros(template.amount ?? 0)) repeat every \(period.amount) \(period.period.rawValue)s starting \(template.starting ?? "")"
            if let limit = template.limit { line += " \(limitToString(limit))" }
            return line
        case .by, .spend:
            var line = "\(prefix) \(trimTrailingZeros(template.amount ?? 0)) by \(template.month ?? "")"
            if template.type == .spend, let from = template.from {
                line += " spend from \(from)"
            }
            if let repeatInfo = repeatToString(annual: template.annual, repeatCount: template.repeatCount) {
                line += " repeat every \(repeatInfo)"
            }
            return line
        case .remainder:
            var line = "\(prefix) remainder"
            if let weight = template.weight, weight != 1 {
                line += " \(trimTrailingZeros(weight))"
            }
            if let limit = template.limit { line += " \(limitToString(limit))" }
            return line
        case .average:
            var line = "\(prefix) average \(template.numMonths ?? 0) months"
            line += adjustmentToString(template)
            return line
        case .copy:
            return "\(prefix) copy from \(template.lookBack ?? 0) months ago"
        case .limit:
            guard let limit = template.limit else { return nil }
            if let refill {
                return "\(prefix(forPriority: refill.priority)) \(limitToString(limit))"
            }
            return "\(prefix) 0 \(limitToString(limit))"
        case .refill, .error:
            return nil
        }
    }

    /// Render a template list as note lines, merging a refill into the limit
    /// line and keeping descriptions above their template line — the web's
    /// `unparse`.
    static func renderNoteTemplates(
        _ templates: [GoalTemplate],
        categoryName: (String) -> String? = { _ in nil }
    ) -> String {
        let refill = templates.first { $0.type == .refill }
        return templates
            .filter { $0.type != .refill }
            .flatMap { template -> [String] in
                guard let line = noteLine(
                    for: template, refill: refill, categoryName: categoryName)
                else { return [] }
                let descriptionLines = (template.description ?? "")
                    .components(separatedBy: "\n")
                    .map { line -> String in
                        var trimmed = line
                        while let last = trimmed.last, last == " " || last == "\t" {
                            trimmed.removeLast()
                        }
                        return trimmed
                    }
                    .filter { !$0.isEmpty }
                return descriptionLines + [line]
            }
            .joined(separator: "\n")
    }

    /// The un-migrate note preview: append rendered template/cleanup lines
    /// that the existing note doesn't already contain — port of the seeding
    /// logic in UnmigrateBudgetAutomationsModal.
    static func mergeIntoNote(existingNote: String, rendered: String) -> String {
        var base = existingNote
        while let last = base.last, last.isWhitespace { base.removeLast() }
        guard !rendered.isEmpty else { return base }

        let existingLines = Set(
            base.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        let newLines = rendered.components(separatedBy: "\n")
            .map { line -> String in
                var trimmed = line
                while let last = trimmed.last, last == " " || last == "\t" { trimmed.removeLast() }
                return trimmed
            }
            .filter { !$0.isEmpty && !existingLines.contains($0.trimmingCharacters(in: .whitespaces)) }

        guard !newLines.isEmpty else { return base }
        let separator = base.isEmpty ? "" : "\n\n"
        return base + separator + "Export from automations UI:\n" + newLines.joined(separator: "\n")
    }
}
