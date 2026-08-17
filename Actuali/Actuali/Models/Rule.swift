import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "Rule")
/// Mirrors loot-core's rule model (`types/models/rule.ts`). Conditions and
/// actions are stored as JSON blobs in the `rules` table using the *internal*
/// schema names (`description` for payee, `acct` for account); `RuleSchema`
/// translates them on the way in and out.
struct Rule: Identifiable, Equatable, Hashable {
    let id: String
    var stage: Stage
    var conditionsOp: ConditionsOp
    var conditions: [Condition]
    var actions: [Action]
    var tombstone: Bool = false

    enum Stage: Int, Comparable, CaseIterable {
        case pre = 0
        case `default` = 1
        case post = 2

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }

        init(raw: String?) {
            switch raw {
            case "pre": self = .pre
            case "post": self = .post
            default: self = .default
            }
        }

        /// The value written to the `stage` column — NULL for the default stage,
        /// same as upstream.
        var storedValue: String? {
            switch self {
            case .pre: return "pre"
            case .post: return "post"
            case .default: return nil
            }
        }

        var label: String {
            switch self {
            case .pre: return "Pre"
            case .default: return "Default"
            case .post: return "Post"
            }
        }
    }

    enum ConditionsOp: String, CaseIterable {
        case and
        case or

        init(raw: String?) {
            self = raw?.lowercased() == "or" ? .or : .and
        }

        var label: String { self == .and ? "all" : "any" }
    }

    struct Condition: Equatable, Hashable {
        var op: String
        var field: String        // public field name, e.g. "imported_payee"
        var value: RuleValue
        var options: [String: RuleValue]?
    }

    struct Action: Equatable, Hashable {
        var op: String
        var field: String?       // nil for ops without a field (link-schedule, …)
        var value: RuleValue
        var options: [String: RuleValue]?
    }

    /// A rule with nothing filled in, for the "new rule" editor.
    static func empty(id: String = UUID().uuidString) -> Rule {
        Rule(id: id, stage: .default, conditionsOp: .and, conditions: [], actions: [])
    }
}

// MARK: - JSON parsing

enum RuleParseError: Error {
    case invalidJSON
    case notArray
    case invalidCondition
    case invalidAction
}

extension Rule {
    /// Parse a single row of the `rules` table.
    static func parse(
        id: String,
        stage: String?,
        conditionsOp: String?,
        conditionsJSON: String?,
        actionsJSON: String?
    ) throws -> Rule {
        Rule(
            id: id,
            stage: Stage(raw: stage),
            conditionsOp: ConditionsOp(raw: conditionsOp),
            conditions: try parseConditions(conditionsJSON),
            actions: try parseActions(actionsJSON)
        )
    }

    private static func parseConditions(_ json: String?) throws -> [Condition] {
        try parseArray(json).map { item in
            // Upstream drops the *whole rule* when any condition fails to parse
            // (`makeRule` returns null). Dropping just the bad condition would
            // leave an `and` rule matching on fewer conditions than its author
            // wrote — firing more broadly, not less.
            guard let op = item["op"] as? String,
                  let field = item["field"] as? String else {
                throw RuleParseError.invalidCondition
            }
            return Condition(
                op: op,
                field: RuleSchema.publicField(from: field),
                value: RuleValue(json: item["value"] ?? nil),
                options: options(from: item["options"])
            )
        }
    }

    private static func parseActions(_ json: String?) throws -> [Action] {
        try parseArray(json).map { item in
            guard let op = item["op"] as? String else { throw RuleParseError.invalidAction }
            return Action(
                op: op,
                field: (item["field"] as? String).map(RuleSchema.publicField(from:)),
                value: RuleValue(json: item["value"] ?? nil),
                options: options(from: item["options"])
            )
        }
    }

    private static func options(from any: Any?) -> [String: RuleValue]? {
        guard let dict = any as? [String: Any], !dict.isEmpty else { return nil }
        return dict.mapValues(RuleValue.init(json:))
    }

    private static func parseArray(_ json: String?) throws -> [[String: Any]] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let array = any as? [[String: Any]] else {
            if any is NSNull { return [] }
            throw RuleParseError.notArray
        }
        return array
    }
}

// MARK: - JSON serialization

extension Rule.Condition {
    /// Upstream `Condition.serialize()` + `toInternalField`.
    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "op": op,
            "field": RuleSchema.internalField(from: field),
            "value": value.jsonObject
        ]
        if let type = RuleSchema.fieldType(field)?.rawValue {
            object["type"] = type
        }
        if let options, !options.isEmpty {
            object["options"] = options.mapValues(\.jsonObject)
        }
        return object
    }
}

extension Rule.Action {
    /// Upstream `Action.serialize()`: `set` carries the field and its type,
    /// `set-split-amount`/`link-schedule`/notes ops carry a null field with a
    /// fixed type, and `delete-transaction` carries neither (JS leaves both
    /// `undefined`, which `JSON.stringify` drops).
    var jsonObject: [String: Any] {
        var object: [String: Any] = ["op": op, "value": value.jsonObject]

        switch op {
        case "set":
            if let field {
                object["field"] = RuleSchema.internalField(from: field)
                if let type = RuleSchema.fieldType(field)?.rawValue { object["type"] = type }
            }
        case "set-split-amount":
            object["field"] = NSNull()
            object["type"] = RuleFieldType.number.rawValue
        case "link-schedule":
            object["field"] = NSNull()
            object["type"] = RuleFieldType.id.rawValue
        case "prepend-notes", "append-notes":
            // Upstream really does tag these `id`; kept for byte parity.
            object["field"] = "notes"
            object["type"] = RuleFieldType.id.rawValue
        default:
            break
        }

        if let options, !options.isEmpty {
            object["options"] = options.mapValues(\.jsonObject)
        }
        return object
    }
}

extension Rule {
    var conditionsJSON: String { Self.encode(conditions.map(\.jsonObject)) }
    var actionsJSON: String { Self.encode(actions.map(\.jsonObject)) }

    private static func encode(_ array: [[String: Any]]) -> String {
        // .sortedKeys so a rule that round-trips through the editor unchanged
        // produces the same bytes, keeping CRDT writes idempotent-looking in
        // review and in tests.
        do {
            let data = try JSONSerialization.data(withJSONObject: array, options: [.sortedKeys])
            if let json = String(data: data, encoding: .utf8) { return json }
        } catch {
            logger.error("Rule serialization failed: \(error.localizedDescription, privacy: .public)")
        }
        // Unreachable once every RuleValue is JSON-legal (see RuleValue.jsonObject).
        // Returning "[]" would sync a blanked rule to every device, so callers
        // that write must check `isSerializable` first — see BudgetStore.validate.
        logger.error("Rule serialization produced no JSON; refusing to blank the rule")
        return "[]"
    }
    
    /// Whether both blobs will survive a round trip to JSON. Checked before a
    /// save so a rule can never be written to the server as an empty one.
    var isSerializable: Bool {
        JSONSerialization.isValidJSONObject(conditions.map(\.jsonObject))
            && JSONSerialization.isValidJSONObject(actions.map(\.jsonObject))
    }
}

// MARK: - CRDTSyncable

extension Rule: CRDTSyncable {
    static var datasetName: String { "rules" }

    var syncableFields: [String: Any?] {
        [
            "stage": stage.storedValue,
            "conditions_op": conditionsOp.rawValue,
            "conditions": conditionsJSON,
            "actions": actionsJSON,
            "tombstone": tombstone ? 1 : 0
        ]
    }
}
