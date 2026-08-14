import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "RulesEngine")

/// Budget-level context for conditions that can't be answered from the
/// transaction row alone. Mirrors what upstream's `prepareTransactionForRules`
/// hangs off the transaction before the rules run.
struct RuleContext {
    var offBudgetAccountIds: Set<String> = []
    var categoryGroupIds: [String: String] = [:]   // category id -> group id
    var payeeNames: [String: String] = [:]         // payee id -> name

    static let empty = RuleContext()
}

/// What a rules pass produced.
struct RuleRunResult {
    var transaction: Transaction
    /// Public rule field names the rules changed ("payee", "category", …), for
    /// logging and for deciding whether a write is needed at all. The CRDT
    /// column set for an update still comes from `BudgetStore.changedFields`,
    /// which speaks the internal column names.
    var changedFields: Set<String>
    /// Set when an action assigned `payee_name`: the caller resolves it to a
    /// payee id, creating the payee if necessary, like upstream's
    /// `resolvePayeeNameForRules`.
    var pendingPayeeName: String?
    /// A `delete-transaction` action fired.
    var isDeleted: Bool = false
}

/// Evaluates Actual Budget rules against a Transaction.
/// Port of loot-core `runRules` (server/transactions/transaction-rules.ts) with
/// the condition/action semantics of `server/rules/{condition,action}.ts`.
///
/// Not supported (logged, treated as a no-op): `set-split-amount`, Handlebars
/// templates and formula actions, and recurring-date conditions. See the
/// deferred-work section of the rules plan.
enum RulesEngine {

    static func apply(
        _ transaction: Transaction,
        rules: [Rule],
        context: RuleContext = .empty
    ) -> RuleRunResult {
        var bag = TransactionBag(transaction, context: context)
        let original = bag.snapshot()

        for rule in RuleRanker.rank(rules) where evalConditions(rule, bag: bag) {
            for action in rule.actions {
                apply(action, bag: &bag, ruleId: rule.id)
            }
        }

        let changed = bag.changedFields(comparedTo: original)
        if !changed.isEmpty {
            logger.info("Rules applied: changed fields \(changed.sorted().joined(separator: ", "), privacy: .public)")
        }

        return RuleRunResult(
            transaction: bag.toTransaction(base: transaction),
            changedFields: changed,
            pendingPayeeName: bag.pendingPayeeName,
            isDeleted: bag.isDeleted
        )
    }

    // MARK: - Condition evaluation

    private static func evalConditions(_ rule: Rule, bag: TransactionBag) -> Bool {
        guard !rule.conditions.isEmpty else { return false }
        switch rule.conditionsOp {
        case .and: return rule.conditions.allSatisfy { eval($0, bag: bag) }
        case .or: return rule.conditions.contains { eval($0, bag: bag) }
        }
    }

    private static func eval(_ condition: Rule.Condition, bag: TransactionBag) -> Bool {
        let type = RuleSchema.fieldType(condition.field)

        // onBudget/offBudget read the account, not the field value.
        switch condition.op {
        case "onBudget": return bag.isOnBudget == true
        case "offBudget": return bag.isOnBudget == false
        default: break
        }

        switch type {
        case .date:
            guard let date = bag.date, let value = condition.value.stringValue else { return false }
            return RuleDateMatcher.matches(transactionDate: date, op: condition.op, value: value) ?? false
        case .number:
            return evalNumber(condition, bag: bag)
        case .boolean:
            guard condition.op == "is",
                  let expected = condition.value.boolValue,
                  let actual = bag.bool(for: condition.field) else { return false }
            return actual == expected
        case .string, .id, .none:
            return evalText(condition, bag: bag, type: type)
        }
    }

    private static func evalNumber(_ condition: Rule.Condition, bag: TransactionBag) -> Bool {
        // Upstream applies inflow/outflow before the switch, so it gates every
        // numeric op, `isbetween` included.
        guard var amount = bag.number(for: condition.field).map(Double.init) else { return false }
        if condition.options?["outflow"]?.boolValue == true {
            guard amount <= 0 else { return false }
            amount = -amount
        } else if condition.options?["inflow"]?.boolValue == true {
            guard amount >= 0 else { return false }
        }

        if condition.op == "isbetween" {
            guard let between = condition.value.betweenValue else { return false }
            let low = min(between.num1, between.num2)
            let high = max(between.num1, between.num2)
            return amount >= low && amount <= high
        }

        guard let target = condition.value.numberValue else { return false }
        switch condition.op {
        case "is": return amount == target
        case "isapprox":
            // getApproxNumberThreshold: Math.round(|n| * 0.075).
            let threshold = (abs(target) * 0.075).rounded()
            return amount >= target - threshold && amount <= target + threshold
        case "gt": return amount > target
        case "gte": return amount >= target
        case "lt": return amount < target
        case "lte": return amount <= target
        default: return false
        }
    }

    private static func evalText(_ condition: Rule.Condition, bag: TransactionBag, type: RuleFieldType?) -> Bool {
        // Upstream coerces a missing string field to "" before comparing; id
        // fields keep their nil so `isNot` still matches an empty payee.
        var fieldValue = bag.string(for: condition.field)
        if type == .string { fieldValue = fieldValue ?? "" }

        switch condition.op {
        case "is":
            guard let condValue = condition.value.stringValue else { return fieldValue == nil }
            return fieldValue?.lowercased() == condValue.lowercased()
        case "isNot":
            guard let condValue = condition.value.stringValue else { return fieldValue != nil }
            return fieldValue?.lowercased() != condValue.lowercased()
        case "contains":
            guard let fieldValue, let condValue = condition.value.stringValue else { return false }
            return fieldValue.lowercased().contains(condValue.lowercased())
        case "doesNotContain":
            guard let fieldValue, let condValue = condition.value.stringValue else { return false }
            return !fieldValue.lowercased().contains(condValue.lowercased())
        case "oneOf", "notOneOf":
            guard let fieldValue, let list = condition.value.listValue else { return false }
            let hit = list.compactMap(\.stringValue)
                .contains { $0.lowercased() == fieldValue.lowercased() }
            return condition.op == "oneOf" ? hit : !hit
        case "matches":
            guard let fieldValue, let pattern = condition.value.stringValue else { return false }
            // Lowercased, not case-insensitive: upstream's string parse does
            // `value.toLowerCase()` on the pattern itself, so `\D` becomes `\d`
            // there and inverts its meaning. Using a case-insensitive match on
            // the raw pattern would be more correct and would make a rule that
            // works on the web behave differently here, so we copy the quirk.
            // Worth an upstream fix in condition.ts; not one to make client-side.
            guard let regex = try? NSRegularExpression(pattern: pattern.lowercased()) else {
                logger.debug("invalid regexp in matches condition")
                return false
            }
            return regex.firstMatch(in: fieldValue, range: NSRange(fieldValue.startIndex..., in: fieldValue)) != nil
        case "hasTags", "hasAnyTag":
            guard let fieldValue, let condValue = condition.value.stringValue else { return false }
            let tags = TagFilter.extractTags(condValue)
            let hit = { (tag: String) in TagFilter.notesContainTag(fieldValue, tag: tag, caseSensitive: false) }
            return condition.op == "hasTags" ? tags.allSatisfy(hit) : tags.contains(where: hit)
        default:
            logger.debug("Unknown condition op '\(condition.op, privacy: .public)'")
            return false
        }
    }

    // MARK: - Action execution

    private static func apply(_ action: Rule.Action, bag: inout TransactionBag, ruleId: String) {
        switch action.op {
        case "set":
            guard let field = action.field else { return }
            if action.options?["template"] != nil || action.options?["formula"] != nil {
                logger.notice("Rule \(ruleId, privacy: .public): skipping set on '\(field, privacy: .public)' — template/formula actions aren't supported on iOS")
                return
            }
            if action.options?["splitIndex"]?.numberValue.map({ $0 > 0 }) == true {
                logger.notice("Rule \(ruleId, privacy: .public): skipping split action on '\(field, privacy: .public)'")
                return
            }
            bag.set(field, to: action.value)

        case "prepend-notes":
            guard let value = action.value.stringValue else { return }
            let existing = bag.string(for: "notes") ?? ""
            bag.set("notes", to: .string(existing.isEmpty ? value : value + existing))

        case "append-notes":
            guard let value = action.value.stringValue else { return }
            let existing = bag.string(for: "notes") ?? ""
            bag.set("notes", to: .string(existing.isEmpty ? value : existing + value))

        case "link-schedule":
            guard let value = action.value.stringValue else { return }
            bag.set("schedule", to: .string(value))

        case "delete-transaction":
            bag.isDeleted = true

        case "set-split-amount":
            logger.notice("Rule \(ruleId, privacy: .public): skipping unsupported action op 'set-split-amount'")

        default:
            logger.notice("Rule \(ruleId, privacy: .public): unknown action op '\(action.op, privacy: .public)'")
        }
    }
}

/// Mutable key-value view of a Transaction keyed by *public* rule field names.
struct TransactionBag {
    private var strings: [String: String?] = [:]
    private var numbers: [String: Int?] = [:]
    private var bools: [String: Bool] = [:]

    /// nil when the transaction's account isn't known to the context.
    let isOnBudget: Bool?
    /// Set when a rule assigned `payee_name`; upstream parks `payee = 'new'` and
    /// resolves the name to an id after every rule has run.
    private(set) var pendingPayeeName: String?
    var isDeleted = false

    init(_ transaction: Transaction, context: RuleContext = .empty) {
        strings = [
            "account": transaction.accountId,
            "payee": transaction.payeeId,
            "payee_name": transaction.payeeId.flatMap { context.payeeNames[$0] } ?? transaction.payeeName,
            "category": transaction.categoryId,
            "category_group": transaction.categoryId.flatMap { context.categoryGroupIds[$0] },
            "notes": transaction.notes,
            "imported_payee": transaction.importedPayee,
            "transfer_id": transaction.transferId,
            "parent_id": transaction.parentId,
            "schedule": transaction.schedule
        ]
        numbers = ["date": transaction.date, "amount": transaction.amount]
        // `cleared` and `reconciled` only. `transfer` and `parent` are absent on
        // purpose: they are not keys of upstream's prepared transaction either,
        // so `Condition.eval` hits `fieldValue === undefined` and returns false
        // for them. Only the query path (`conditionsToAQL`, mirrored by
        // ConditionsFilter) maps them to real columns.
        bools = [
            "cleared": transaction.cleared,
            "reconciled": transaction.reconciled
        ]
        // Upstream reads `_account.offbudget`, and an unknown account means the
        // condition can't match either way.
        isOnBudget = transaction.accountId.isEmpty
            ? nil
            : !context.offBudgetAccountIds.contains(transaction.accountId)
    }

    var date: Int? { numbers["date"] ?? nil }

    func string(for field: String) -> String? { strings[field] ?? nil }
    func number(for field: String) -> Int? { numbers[field] ?? nil }
    func bool(for field: String) -> Bool? { bools[field] }

    mutating func set(_ field: String, to value: RuleValue) {
        switch RuleSchema.fieldType(field) {
        case .number:
            // Garbage in a rule (a non-finite or out-of-range amount) is not a
            // change: skip the write so the original amount survives and
            // `changedFields` doesn't claim an edit that didn't happen. See
            // RulesEngineTests.setAmountNonFiniteLeavesAmountUnchanged.
            if let number = value.numberValue, let cents = Int(exactly: number.rounded()) {
                numbers[field] = cents
            }
        case .boolean:
            if let flag = value.boolValue { bools[field] = flag }
        case .date:
            // A `set date` action carries "yyyy-MM-dd"; the column is YYYYMMDD.
            if let text = value.stringValue,
               let day = Int(text.replacingOccurrences(of: "-", with: "")), day > 9_999_999 {
                numbers["date"] = day
            }
        default:
            strings[field] = value.stringValue
            if field == "payee_name" {
                // Upstream: setting payee_name parks payee = 'new'.
                pendingPayeeName = value.stringValue
                strings["payee"] = nil
            }
            if field == "payee" {
                pendingPayeeName = nil
            }
        }
    }

    func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in strings { out[key] = value.map { "s:" + $0 } ?? "nil" }
        for (key, value) in numbers { out[key] = value.map { "i:\($0)" } ?? "nil" }
        for (key, value) in bools { out[key] = "b:\(value)" }
        return out
    }

    func changedFields(comparedTo prior: [String: String]) -> Set<String> {
        Set(snapshot().compactMap { key, value in prior[key] == value ? nil : key })
    }

    func toTransaction(base: Transaction) -> Transaction {
        var transaction = base
        if let accountId = string(for: "account") { transaction.accountId = accountId }
        if let date = number(for: "date") { transaction.date = date }
        if let amount = number(for: "amount") { transaction.amount = amount }
        transaction.payeeId = string(for: "payee")
        transaction.categoryId = string(for: "category")
        transaction.notes = string(for: "notes")
        transaction.importedPayee = string(for: "imported_payee")
        transaction.transferId = string(for: "transfer_id")
        transaction.parentId = string(for: "parent_id")
        transaction.schedule = string(for: "schedule")
        transaction.cleared = bool(for: "cleared") ?? base.cleared
        transaction.reconciled = bool(for: "reconciled") ?? base.reconciled
        transaction.tombstone = isDeleted || base.tombstone
        return transaction
    }
}
