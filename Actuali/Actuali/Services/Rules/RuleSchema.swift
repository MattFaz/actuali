import Foundation

/// Field metadata for rules, ported from loot-core `shared/rules.ts` (FIELD_INFO,
/// TYPE_INFO, isValidOp) plus the label maps in `desktop-client/src/util/rule.ts`.
/// One place so the engine, the validator and the editor can't drift apart.
enum RuleFieldType: String {
    case id, string, number, date, boolean
}

enum RuleSchema {

    // MARK: - Types and operators

    /// Public field name -> type. `saved` (saved-filter references) is
    /// deliberately absent: upstream drops those conditions before evaluating.
    static let fieldTypes: [String: RuleFieldType] = [
        "imported_payee": .string,
        "payee": .id,
        "payee_name": .string,
        "date": .date,
        "notes": .string,
        "amount": .number,
        "category": .id,
        "category_group": .id,
        "account": .id,
        "cleared": .boolean,
        "reconciled": .boolean,
        "transfer": .boolean,
        "parent": .boolean
    ]

    private static let opsByType: [RuleFieldType: [String]] = [
        .date: ["is", "isapprox", "gt", "gte", "lt", "lte"],
        .id: ["is", "isNot", "oneOf", "notOneOf", "contains", "doesNotContain",
              "matches", "onBudget", "offBudget"],
        .string: ["is", "isNot", "oneOf", "notOneOf", "contains", "doesNotContain",
                  "matches", "hasTags", "hasAnyTag"],
        .number: ["is", "isapprox", "isbetween", "gt", "gte", "lt", "lte"],
        .boolean: ["is"]
    ]

    private static let disallowedOps: [String: Set<String>] = [
        "imported_payee": ["hasTags", "hasAnyTag"],
        "payee": ["onBudget", "offBudget"],
        "category": ["onBudget", "offBudget"],
        "category_group": ["onBudget", "offBudget"],
        "notes": ["oneOf", "notOneOf"]
    ]

    static func fieldType(_ field: String) -> RuleFieldType? {
        fieldTypes[field]
    }

    /// Ops the editor offers for `field`, in upstream's declaration order.
    static func validOps(for field: String) -> [String] {
        guard let type = fieldTypes[field] else { return [] }
        let disallowed = disallowedOps[field] ?? []
        return (opsByType[type] ?? []).filter { !disallowed.contains($0) }
    }

    static func isValidOp(field: String, op: String) -> Bool {
        validOps(for: field).contains(op)
    }

    // MARK: - Editor field lists (upstream RuleEditor.tsx)

    static let conditionFields = [
        "imported_payee", "account", "category", "category_group",
        "date", "payee", "notes", "amount"
    ]

    static let actionFields = [
        "category", "payee", "payee_name", "notes", "cleared", "account", "date", "amount"
    ]

    // MARK: - Internal <-> public column names

    /// Mirrors `schemaConfig.views.transactions.fields` in loot-core.
    private static let internalToPublic: [String: String] = [
        "isParent": "is_parent",
        "isChild": "is_child",
        "acct": "account",
        "financial_id": "imported_id",
        "imported_description": "imported_payee",
        "transferred_id": "transfer_id",
        "description": "payee"
    ]

    private static let publicToInternal: [String: String] =
        Dictionary(uniqueKeysWithValues: internalToPublic.map { ($0.value, $0.key) })

    static func publicField(from internalField: String) -> String {
        internalToPublic[internalField] ?? internalField
    }

    static func internalField(from publicField: String) -> String {
        publicToInternal[publicField] ?? publicField
    }

    // MARK: - Labels (util/rule.ts mapField / friendlyOp)

    static func label(
        field: String,
        options: [String: RuleValue]? = nil,
        locale: Locale = .autoupdatingCurrent,
        bundle: Bundle = .main
    ) -> String {
        switch field {
        case "imported_payee": return ReportStrings.text("rule.field.importedPayee", locale: locale, bundle: bundle)
        case "payee_name": return ReportStrings.text("rule.field.payeeName", locale: locale, bundle: bundle)
        case "amount":
            if options?["inflow"]?.boolValue == true {
                return ReportStrings.text("rule.field.amountInflow", locale: locale, bundle: bundle)
            }
            if options?["outflow"]?.boolValue == true {
                return ReportStrings.text("rule.field.amountOutflow", locale: locale, bundle: bundle)
            }
            return ReportStrings.text("rule.field.amount", locale: locale, bundle: bundle)
        case "category_group": return ReportStrings.text("rule.field.categoryGroup", locale: locale, bundle: bundle)
        case "payee": return ReportStrings.text("rule.field.payee", locale: locale, bundle: bundle)
        case "category": return ReportStrings.text("rule.field.category", locale: locale, bundle: bundle)
        case "account": return ReportStrings.text("rule.field.account", locale: locale, bundle: bundle)
        case "date": return ReportStrings.text("rule.field.date", locale: locale, bundle: bundle)
        case "notes": return ReportStrings.text("rule.field.notes", locale: locale, bundle: bundle)
        case "cleared": return ReportStrings.text("rule.field.cleared", locale: locale, bundle: bundle)
        case "reconciled": return ReportStrings.text("rule.field.reconciled", locale: locale, bundle: bundle)
        case "transfer": return ReportStrings.text("rule.field.transfer", locale: locale, bundle: bundle)
        case "parent": return ReportStrings.text("rule.field.parent", locale: locale, bundle: bundle)
        default: return field
        }
    }

    static func summaryLabel(
        field: String,
        options: [String: RuleValue]? = nil,
        locale: Locale = .autoupdatingCurrent,
        bundle: Bundle = .main
    ) -> String {
        switch field {
        case "payee": return ReportStrings.text("rule.summary.field.payee", locale: locale, bundle: bundle)
        case "category": return ReportStrings.text("rule.summary.field.category", locale: locale, bundle: bundle)
        case "account": return ReportStrings.text("rule.summary.field.account", locale: locale, bundle: bundle)
        case "date": return ReportStrings.text("rule.summary.field.date", locale: locale, bundle: bundle)
        case "notes": return ReportStrings.text("rule.summary.field.notes", locale: locale, bundle: bundle)
        case "cleared": return ReportStrings.text("rule.summary.field.cleared", locale: locale, bundle: bundle)
        case "reconciled": return ReportStrings.text("rule.summary.field.reconciled", locale: locale, bundle: bundle)
        case "transfer": return ReportStrings.text("rule.summary.field.transfer", locale: locale, bundle: bundle)
        case "parent": return ReportStrings.text("rule.summary.field.parent", locale: locale, bundle: bundle)
        default: return label(field: field, options: options, locale: locale, bundle: bundle)
        }
    }

    static func label(
        op: String,
        type: RuleFieldType? = nil,
        locale: Locale = .autoupdatingCurrent,
        bundle: Bundle = .main
    ) -> String {
        let key: String
        switch op {
        case "is": key = "rule.op.is"
        case "isNot": key = "rule.op.isNot"
        case "oneOf": key = "rule.op.oneOf"
        case "notOneOf": key = "rule.op.notOneOf"
        case "isapprox": key = "rule.op.isApprox"
        case "isbetween": key = "rule.op.isBetween"
        case "contains": key = "rule.op.contains"
        case "doesNotContain": key = "rule.op.doesNotContain"
        case "matches": key = "rule.op.matches"
        case "hasTags": key = "rule.op.hasAllTags"
        case "hasAnyTag": key = "rule.op.hasAnyTag"
        case "onBudget": key = "rule.op.isOnBudget"
        case "offBudget": key = "rule.op.isOffBudget"
        case "gt": key = type == .date ? "rule.op.isAfter" : "rule.op.isGreaterThan"
        case "gte": key = type == .date ? "rule.op.isAfterOrEquals" : "rule.op.isGreaterThanOrEquals"
        case "lt": key = type == .date ? "rule.op.isBefore" : "rule.op.isLessThan"
        case "lte": key = type == .date ? "rule.op.isBeforeOrEquals" : "rule.op.isLessThanOrEquals"
        case "set": key = "rule.op.set"
        case "set-split-amount": key = "rule.op.allocate"
        case "link-schedule": key = "rule.op.linkSchedule"
        case "prepend-notes": key = "rule.op.prependNotes"
        case "append-notes": key = "rule.op.appendNotes"
        case "delete-transaction": key = "rule.op.deleteTransaction"
        default: return op
        }
        return ReportStrings.text(key, locale: locale, bundle: bundle)
    }

    static func sentenceCased(_ text: String, locale: Locale) -> String {
        text.prefix(1).uppercased(with: locale) + text.dropFirst()
    }
}
