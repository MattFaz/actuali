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

    static func label(field: String, options: [String: RuleValue]? = nil) -> String {
        switch field {
        case "imported_payee": return String(localized: "rule.field.importedPayee")
        case "payee_name": return String(localized: "rule.field.payeeName")
        case "amount":
            if options?["inflow"]?.boolValue == true { return String(localized: "rule.field.amountInflow") }
            if options?["outflow"]?.boolValue == true { return String(localized: "rule.field.amountOutflow") }
            return String(localized: "rule.field.amount")
        case "category_group": return String(localized: "rule.field.categoryGroup")
        case "payee": return String(localized: "rule.field.payee")
        case "category": return String(localized: "rule.field.category")
        case "account": return String(localized: "rule.field.account")
        case "date": return String(localized: "rule.field.date")
        case "notes": return String(localized: "rule.field.notes")
        case "cleared": return String(localized: "rule.field.cleared")
        case "reconciled": return String(localized: "rule.field.reconciled")
        case "transfer": return String(localized: "rule.field.transfer")
        case "parent": return String(localized: "rule.field.parent")
        default: return field
        }
    }

    static func summaryLabel(field: String, options: [String: RuleValue]? = nil) -> String {
        switch field {
        case "payee": return String(localized: "rule.summary.field.payee")
        case "category": return String(localized: "rule.summary.field.category")
        case "account": return String(localized: "rule.summary.field.account")
        case "date": return String(localized: "rule.summary.field.date")
        case "notes": return String(localized: "rule.summary.field.notes")
        case "cleared": return String(localized: "rule.summary.field.cleared")
        case "reconciled": return String(localized: "rule.summary.field.reconciled")
        case "transfer": return String(localized: "rule.summary.field.transfer")
        case "parent": return String(localized: "rule.summary.field.parent")
        default: return label(field: field, options: options)
        }
    }

    static func label(op: String, type: RuleFieldType? = nil) -> String {
        switch op {
        case "is": return String(localized: "rule.op.is")
        case "isNot": return String(localized: "rule.op.isNot")
        case "oneOf": return String(localized: "rule.op.oneOf")
        case "notOneOf": return String(localized: "rule.op.notOneOf")
        case "isapprox": return String(localized: "rule.op.isApprox")
        case "isbetween": return String(localized: "rule.op.isBetween")
        case "contains": return String(localized: "rule.op.contains")
        case "doesNotContain": return String(localized: "rule.op.doesNotContain")
        case "matches": return String(localized: "rule.op.matches")
        case "hasTags": return String(localized: "rule.op.hasAllTags")
        case "hasAnyTag": return String(localized: "rule.op.hasAnyTag")
        case "onBudget": return String(localized: "rule.op.isOnBudget")
        case "offBudget": return String(localized: "rule.op.isOffBudget")
        case "gt": return String(localized: type == .date ? "rule.op.isAfter" : "rule.op.isGreaterThan")
        case "gte": return String(localized: type == .date ? "rule.op.isAfterOrEquals" : "rule.op.isGreaterThanOrEquals")
        case "lt": return String(localized: type == .date ? "rule.op.isBefore" : "rule.op.isLessThan")
        case "lte": return String(localized: type == .date ? "rule.op.isBeforeOrEquals" : "rule.op.isLessThanOrEquals")
        case "set": return String(localized: "rule.op.set")
        case "set-split-amount": return String(localized: "rule.op.allocate")
        case "link-schedule": return String(localized: "rule.op.linkSchedule")
        case "prepend-notes": return String(localized: "rule.op.prependNotes")
        case "append-notes": return String(localized: "rule.op.appendNotes")
        case "delete-transaction": return String(localized: "rule.op.deleteTransaction")
        default: return op
        }
    }
}
