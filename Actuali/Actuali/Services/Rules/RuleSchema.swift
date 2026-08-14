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
        case "imported_payee": return "imported payee"
        case "payee_name": return "payee (name)"
        case "amount":
            if options?["inflow"]?.boolValue == true { return "amount (inflow)" }
            if options?["outflow"]?.boolValue == true { return "amount (outflow)" }
            return "amount"
        case "category_group": return "category group"
        default: return field
        }
    }

    static func label(op: String, type: RuleFieldType? = nil) -> String {
        switch op {
        case "is": return "is"
        case "isNot": return "is not"
        case "oneOf": return "one of"
        case "notOneOf": return "not one of"
        case "isapprox": return "is approx"
        case "isbetween": return "is between"
        case "contains": return "contains"
        case "doesNotContain": return "does not contain"
        case "matches": return "matches"
        case "hasTags": return "has all tags"
        case "hasAnyTag": return "has any tag"
        case "onBudget": return "is on budget"
        case "offBudget": return "is off budget"
        case "gt": return type == .date ? "is after" : "is greater than"
        case "gte": return type == .date ? "is after or equals" : "is greater than or equals"
        case "lt": return type == .date ? "is before" : "is less than"
        case "lte": return type == .date ? "is before or equals" : "is less than or equals"
        case "set": return "set"
        case "set-split-amount": return "allocate"
        case "link-schedule": return "link schedule"
        case "prepend-notes": return "prepend to notes"
        case "append-notes": return "append to notes"
        case "delete-transaction": return "delete transaction"
        default: return op
        }
    }
}
