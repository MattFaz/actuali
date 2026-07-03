import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "RulesEngine")

/// Evaluates Actual Budget rules against a Transaction before insert.
/// Mirrors a subset of loot-core's `runRules` — see Rule.swift for scope.
enum RulesEngine {

    /// Apply all non-tombstoned rules to `transaction` in stage order
    /// (pre → default → post). Returns the (possibly-updated) transaction
    /// and the set of public field names that changed.
    static func apply(_ transaction: Transaction, rules: [Rule]) -> (Transaction, Set<String>) {
        var bag = TransactionBag(transaction)
        let original = bag.snapshot()

        let ordered = rules.sorted { $0.stage < $1.stage }
        for rule in ordered {
            if evalConditions(rule, bag: bag) {
                for action in rule.actions {
                    apply(action, bag: &bag, ruleId: rule.id)
                }
            }
        }

        let updated = bag.toTransaction(base: transaction)
        let changed = bag.changedFields(comparedTo: original)
        if !changed.isEmpty {
            logger.info("Rules applied: changed fields \(changed.sorted().joined(separator: ", "), privacy: .public)")
        }
        return (updated, changed)
    }

    // MARK: - Condition evaluation

    private static func evalConditions(_ rule: Rule, bag: TransactionBag) -> Bool {
        guard !rule.conditions.isEmpty else { return false }
        switch rule.conditionsOp {
        case .and: return rule.conditions.allSatisfy { eval($0, bag: bag) }
        case .or:  return rule.conditions.contains { eval($0, bag: bag) }
        }
    }

    private static func eval(_ cond: Rule.Condition, bag: TransactionBag) -> Bool {
        let raw = bag.value(for: cond.field)

        switch cond.op {
        case "is":          return isEqual(raw, to: cond.value, options: cond.options)
        case "isNot":       return !isEqual(raw, to: cond.value, options: cond.options)
        case "contains":    return containsString(raw, cond.value)
        case "doesNotContain":
            guard let s = stringValue(raw) else { return false }
            guard let q = stringValue(cond.value) else { return false }
            return !s.lowercased().contains(q.lowercased())
        case "oneOf":       return inList(raw, cond.value)
        case "notOneOf":
            guard raw != nil else { return false }
            return !inList(raw, cond.value)
        case "matches":
            guard let s = stringValue(raw), let pattern = stringValue(cond.value) else { return false }
            return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))
                .map { $0.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil } ?? false
        case "gt", "gte", "lt", "lte":
            return compareNumeric(raw, cond.value, op: cond.op, options: cond.options)
        case "isbetween":
            guard let n = numericValue(raw, options: cond.options) else { return false }
            guard let dict = cond.value as? [String: Any],
                  let a = numericValue(dict["num1"]),
                  let b = numericValue(dict["num2"]) else { return false }
            let (lo, hi) = a <= b ? (a, b) : (b, a)
            return n >= lo && n <= hi
        case "isapprox":
            guard let n = numericValue(raw, options: cond.options),
                  let target = numericValue(cond.value) else { return false }
            // Upstream: getApproxNumberThreshold returns floor(|n| * 7.5%).
            let threshold = floor(abs(target) * 0.075)
            return n >= target - threshold && n <= target + threshold
        case "hasTags", "hasAnyTag":
            // Upstream lowercases both the string field value and each tag, so
            // rule-engine tag matching is case-insensitive (unlike AQL filters).
            guard let s = stringValue(raw), let condValue = stringValue(cond.value) else { return false }
            let tags = TagFilter.extractTags(condValue)
            let hit = { (tag: String) in
                TagFilter.notesContainTag(s, tag: tag, caseSensitive: false)
            }
            return cond.op == "hasTags" ? tags.allSatisfy(hit) : tags.contains(where: hit)
        case "onBudget", "offBudget":
            logger.debug("Skipping unsupported condition op '\(cond.op, privacy: .public)' on field '\(cond.field, privacy: .public)'")
            return false
        default:
            logger.debug("Unknown condition op '\(cond.op, privacy: .public)'")
            return false
        }
    }

    // MARK: - Action execution

    private static func apply(_ action: Rule.Action, bag: inout TransactionBag, ruleId: String) {
        switch action.op {
        case "set":
            guard let field = action.field else { return }
            if action.options?["template"] != nil || action.options?["formula"] != nil {
                logger.notice("Rule \(ruleId, privacy: .public): skipping set on '\(field, privacy: .public)' — formula/template actions not supported on iOS")
                return
            }
            bag.set(field, to: action.value)

        case "prepend-notes":
            guard let s = stringValue(action.value) else { return }
            let existing = stringValue(bag.value(for: "notes")) ?? ""
            bag.set("notes", to: existing.isEmpty ? s : s + existing)

        case "append-notes":
            guard let s = stringValue(action.value) else { return }
            let existing = stringValue(bag.value(for: "notes")) ?? ""
            bag.set("notes", to: existing.isEmpty ? s : existing + s)

        case "link-schedule", "set-split-amount", "delete-transaction":
            logger.notice("Rule \(ruleId, privacy: .public): skipping unsupported action op '\(action.op, privacy: .public)'")

        default:
            logger.notice("Rule \(ruleId, privacy: .public): unknown action op '\(action.op, privacy: .public)'")
        }
    }

    // MARK: - Helpers

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if any is NSNull { return nil }
        return nil
    }

    private static func numericValue(_ any: Any?, options: [String: Any]? = nil) -> Double? {
        let n: Double?
        if let d = any as? Double { n = d }
        else if let i = any as? Int { n = Double(i) }
        else if let n2 = any as? NSNumber { n = n2.doubleValue }
        else { n = nil }

        guard var v = n else { return nil }
        if let options {
            if options["outflow"] as? Bool == true {
                if v > 0 { return nil }
                v = -v
            } else if options["inflow"] as? Bool == true {
                if v < 0 { return nil }
            }
        }
        return v
    }

    private static func isEqual(_ a: Any?, to b: Any?, options: [String: Any]?) -> Bool {
        // Numeric comparison preferred when both sides are numeric
        if let na = numericValue(a, options: options), let nb = numericValue(b) {
            return na == nb
        }
        // String — case-insensitive (matches upstream which lowercases)
        if let sa = stringValue(a), let sb = stringValue(b) {
            return sa.lowercased() == sb.lowercased()
        }
        // Bool
        if let ba = a as? Bool, let bb = b as? Bool { return ba == bb }
        // Both nil
        if a == nil && b == nil { return true }
        if a is NSNull && b == nil { return true }
        if a == nil && b is NSNull { return true }
        return false
    }

    private static func containsString(_ haystack: Any?, _ needle: Any?) -> Bool {
        guard let s = stringValue(haystack), let q = stringValue(needle) else { return false }
        return s.lowercased().contains(q.lowercased())
    }

    private static func inList(_ value: Any?, _ list: Any?) -> Bool {
        guard let arr = list as? [Any] else { return false }
        return arr.contains { isEqual(value, to: $0, options: nil) }
    }

    private static func compareNumeric(_ a: Any?, _ b: Any?, op: String, options: [String: Any]?) -> Bool {
        guard let na = numericValue(a, options: options), let nb = numericValue(b) else { return false }
        switch op {
        case "gt": return na > nb
        case "gte": return na >= nb
        case "lt": return na < nb
        case "lte": return na <= nb
        default: return false
        }
    }
}

/// Mutable key-value view of a Transaction keyed by *public* field names.
/// Lets the rule engine read/write fields uniformly without hard-coding
/// every Transaction property.
struct TransactionBag {
    private var fields: [String: Any?]

    init(_ t: Transaction) {
        fields = [
            "id": t.id,
            "account": t.accountId,
            "date": t.date,
            "amount": t.amount,
            "payee": t.payeeId as Any?,
            "category": t.categoryId as Any?,
            "notes": t.notes as Any?,
            "cleared": t.cleared,
            "reconciled": t.reconciled,
            "transfer_id": t.transferId as Any?,
            "is_parent": t.isParent,
            "is_child": t.parentId != nil,
            "parent_id": t.parentId as Any?,
            "tombstone": t.tombstone,
            "imported_payee": t.importedPayee as Any?,
        ]
    }

    func value(for field: String) -> Any? {
        guard let v = fields[field] else { return nil }
        return v ?? nil
    }

    mutating func set(_ field: String, to value: Any?) {
        fields[field] = value
    }

    func snapshot() -> [String: String?] {
        // Use a string-coerced snapshot for change detection — sidesteps Any
        // equality. Good enough since we only care about which fields changed.
        var out: [String: String?] = [:]
        for (k, v) in fields {
            out[k] = describe(v)
        }
        return out
    }

    func changedFields(comparedTo prior: [String: String?]) -> Set<String> {
        var changed: Set<String> = []
        for (k, v) in fields {
            let now = describe(v)
            let then = prior[k] ?? nil
            if now != then { changed.insert(k) }
        }
        return changed
    }

    func toTransaction(base: Transaction) -> Transaction {
        var t = base
        if let v = fields["account"] as? String { t.accountId = v }
        if let v = fields["date"] as? Int { t.date = v }
        if let v = fields["amount"] as? Int { t.amount = v }
        else if let d = fields["amount"] as? Double,
                let v = Int(exactly: d.rounded()) { t.amount = v }
        t.payeeId = fields["payee"].flatMap { $0 as? String }
        t.categoryId = fields["category"].flatMap { $0 as? String }
        t.notes = fields["notes"].flatMap { $0 as? String }
        if let v = fields["cleared"] as? Bool { t.cleared = v }
        if let v = fields["reconciled"] as? Bool { t.reconciled = v }
        t.transferId = fields["transfer_id"].flatMap { $0 as? String }
        if let v = fields["is_parent"] as? Bool { t.isParent = v }
        t.parentId = fields["parent_id"].flatMap { $0 as? String }
        if let v = fields["tombstone"] as? Bool { t.tombstone = v }
        t.importedPayee = fields["imported_payee"].flatMap { $0 as? String }
        return t
    }

    private func describe(_ any: Any?) -> String? {
        guard let any else { return nil }
        if any is NSNull { return nil }
        if let s = any as? String { return "s:" + s }
        if let i = any as? Int { return "i:\(i)" }
        if let d = any as? Double { return "d:\(d)" }
        if let b = any as? Bool { return "b:\(b)" }
        return "x:\(any)"
    }
}
