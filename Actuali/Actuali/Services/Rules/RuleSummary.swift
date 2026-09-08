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
    let formatAmount: (Int) -> String

    func condition(_ condition: Rule.Condition) -> String {
        let field = RuleSchema.summaryLabel(field: condition.field, options: condition.options)
        let op = RuleSchema.label(op: condition.op, type: RuleSchema.fieldType(condition.field))
        switch condition.op {
        case "onBudget", "offBudget":
            return String(format: String(localized: "%@ %@"), field, op)
        default:
            return String(format: String(localized: "%@ %@ %@"), field, op, value(condition.value, field: condition.field))
        }
    }

    func action(_ action: Rule.Action) -> String {
        switch action.op {
        case "set":
            guard let field = action.field else { return RuleSchema.label(op: action.op) }
            if let template = action.options?["template"]?.stringValue {
                return String(format: String(localized: "set %@ to template %@"), RuleSchema.summaryLabel(field: field), template)
            }
            if let formula = action.options?["formula"]?.stringValue {
                return String(format: String(localized: "set %@ to formula %@"), RuleSchema.summaryLabel(field: field), formula)
            }
            return String(format: String(localized: "set %@ to %@"), RuleSchema.summaryLabel(field: field), value(action.value, field: field))
        case "prepend-notes", "append-notes":
            return String(format: String(localized: "%@ %@"), RuleSchema.label(op: action.op), action.value.stringValue ?? "")
        case "link-schedule":
            return String(localized: "link schedule")
        case "delete-transaction":
            return String(localized: "delete transaction")
        case "set-split-amount":
            return String(localized: "allocate a split amount")
        default:
            return RuleSchema.label(op: action.op)
        }
    }

    /// Everything a rule says, in one line — the string the search box filters on.
    func searchText(_ rule: Rule) -> String {
        (rule.conditions.map(condition) + rule.actions.map(action))
            .joined(separator: " ")
            .lowercased()
    }

    private func value(_ value: RuleValue, field: String) -> String {
        switch value {
        case .null:
            return String(localized: "nothing")
        case .bool(let flag):
            return flag ? String(localized: "yes") : String(localized: "no")
        case .list(let items):
            let rendered = items.map { self.value($0, field: field) }
            return rendered.isEmpty ? String(localized: "nothing") : rendered.joined(separator: ", ")
        case .object:
            guard let between = value.betweenValue else { return "" }
            return String(format: String(localized: "%@ and %@"), formatAmount(Int(between.num1)), formatAmount(Int(between.num2)))
        case .number(let number):
            guard RuleSchema.fieldType(field) == .number else { return "\(Int(number))" }
            return formatAmount(Int(number))
        case .string(let text):
            switch field {
            case "payee": return names.payees[text] ?? text
            case "category": return names.categories[text] ?? text
            case "category_group": return names.categoryGroups[text] ?? text
            case "account": return names.accounts[text] ?? text
            default: return text.isEmpty ? String(localized: "nothing") : text
            }
        }
    }
}
