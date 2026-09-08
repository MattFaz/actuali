import Foundation

/// Human-readable rule text, ported from `desktop-client/src/components/rules/
/// {Condition,Action}Expression.tsx` and `ManageRules.tsx`'s `ruleToString`
/// (which is also what the web's rule search matches against).
struct RuleSummary {
    /// Names for the ids a rule references, so the summary reads
    /// "Groceries" rather than a UUID.
    struct Names {
        var payees: [String: String] = [:]
        var categories: [String: String] = [:]
        var categoryGroups: [String: String] = [:]
        var accounts: [String: String] = [:]

        static let empty = Names()
    }

    let names: Names
    /// Formats cents the way the rest of the app does (`BudgetStore.formatCurrency`).
    let formatAmount: (Int, Locale) -> String

    func condition(
        _ condition: Rule.Condition,
        locale: Locale = .autoupdatingCurrent,
        bundle: Bundle = .main
    ) -> String {
        let field = RuleSchema.summaryLabel(
            field: condition.field, options: condition.options,
            locale: locale, bundle: bundle)
        let op = RuleSchema.label(
            op: condition.op, type: RuleSchema.fieldType(condition.field),
            locale: locale, bundle: bundle)
        switch condition.op {
        case "onBudget", "offBudget":
            return ReportStrings.format("%@ %@", field, op, locale: locale, bundle: bundle)
        default:
            return ReportStrings.format(
                "%@ %@ %@", field, op,
                value(condition.value, field: condition.field, locale: locale, bundle: bundle),
                locale: locale, bundle: bundle)
        }
    }

    func action(
        _ action: Rule.Action,
        locale: Locale = .autoupdatingCurrent,
        bundle: Bundle = .main
    ) -> String {
        switch action.op {
        case "set":
            guard let field = action.field else {
                return RuleSchema.label(op: action.op, locale: locale, bundle: bundle)
            }
            let fieldLabel = RuleSchema.summaryLabel(field: field, locale: locale, bundle: bundle)
            if let template = action.options?["template"]?.stringValue {
                return ReportStrings.format(
                    "set %@ to template %@", fieldLabel, template,
                    locale: locale, bundle: bundle)
            }
            if let formula = action.options?["formula"]?.stringValue {
                return ReportStrings.format(
                    "set %@ to formula %@", fieldLabel, formula,
                    locale: locale, bundle: bundle)
            }
            return ReportStrings.format(
                "set %@ to %@", fieldLabel,
                value(action.value, field: field, locale: locale, bundle: bundle),
                locale: locale, bundle: bundle)
        case "prepend-notes", "append-notes":
            return ReportStrings.format(
                "%@ %@", RuleSchema.label(op: action.op, locale: locale, bundle: bundle),
                action.value.stringValue ?? "", locale: locale, bundle: bundle)
        case "link-schedule":
            return ReportStrings.text("link schedule", locale: locale, bundle: bundle)
        case "delete-transaction":
            return ReportStrings.text("delete transaction", locale: locale, bundle: bundle)
        case "set-split-amount":
            return ReportStrings.text("allocate a split amount", locale: locale, bundle: bundle)
        default:
            return RuleSchema.label(op: action.op, locale: locale, bundle: bundle)
        }
    }

    /// Everything a rule says, in one line — the string the search box filters on.
    func searchText(
        _ rule: Rule,
        locale: Locale = .autoupdatingCurrent,
        bundle: Bundle = .main
    ) -> String {
        (rule.conditions.map { condition($0, locale: locale, bundle: bundle) }
         + rule.actions.map { action($0, locale: locale, bundle: bundle) })
            .joined(separator: " ")
            .lowercased(with: locale)
    }

    private func value(
        _ value: RuleValue,
        field: String,
        locale: Locale,
        bundle: Bundle
    ) -> String {
        switch value {
        case .null:
            return ReportStrings.text("nothing", locale: locale, bundle: bundle)
        case .bool(let flag):
            return ReportStrings.text(flag ? "yes" : "no", locale: locale, bundle: bundle)
        case .list(let items):
            let rendered = items.map {
                self.value($0, field: field, locale: locale, bundle: bundle)
            }
            return rendered.isEmpty
                ? ReportStrings.text("nothing", locale: locale, bundle: bundle)
                : rendered.joined(separator: ", ")
        case .object:
            guard let between = value.betweenValue else { return "" }
            return ReportStrings.format(
                "%@ and %@", formatAmount(Int(between.num1), locale),
                formatAmount(Int(between.num2), locale), locale: locale, bundle: bundle)
        case .number(let number):
            guard RuleSchema.fieldType(field) == .number else { return "\(Int(number))" }
            return formatAmount(Int(number), locale)
        case .string(let text):
            switch field {
            case "payee": return names.payees[text] ?? text
            case "category": return names.categories[text] ?? text
            case "category_group": return names.categoryGroups[text] ?? text
            case "account": return names.accounts[text] ?? text
            default:
                return text.isEmpty
                    ? ReportStrings.text("nothing", locale: locale, bundle: bundle)
                    : text
            }
        }
    }
}
