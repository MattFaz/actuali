import Foundation

/// The four fields a schedule owns, as edited in the form. Mirrors the web's
/// `ScheduleFormFields`.
struct ScheduleFormFields: Equatable {
    var name: String?
    var payeeId: String?
    var accountId: String?
    var amount: ScheduledAmount?
    var amountOp: ScheduleAmountOp = .isApprox
    var date: ScheduleDateCondition?
    var postsTransaction: Bool = false
    var customUpcomingLength: String?

    /// Trimmed, with blank treated as "no name" — loot-core
    /// `normalizeScheduleName`, which stores null rather than an empty string
    /// so the uniqueness check doesn't collide every unnamed schedule.
    var normalizedName: String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

enum ScheduleWriteError: LocalizedError, Equatable {
    case dateRequired
    case amountRequired
    case duplicateName(String)
    case unsupportedRecurrence

    var errorDescription: String? {
        switch self {
        case .dateRequired: "A date is required."
        case .amountRequired: "A valid amount is required."
        case .duplicateName(let name): "Another schedule is already called “\(name)”."
        case .unsupportedRecurrence: "This repeat pattern isn't supported."
        }
    }
}

/// Building and merging the rule conditions that carry a schedule's fields.
///
/// Upstream does this in two stages and both are reproduced here: the client
/// builds the four schedule conditions from the form, and the server merges
/// them into the rule's full condition array so custom conditions survive.
enum ScheduleConditions {

    /// Positions of the four schedule-owned conditions inside a rule's full
    /// conditions array.
    ///
    /// Upstream's `extractScheduleConds` returns the condition objects and
    /// later compares them by reference (`cond === r[0]`). Swift value types
    /// make that impossible, so this port carries indices instead — which is
    /// also exactly what the JSON-path cache needs to write `$[n]`.
    struct Indices: Equatable {
        var payee: Int?
        var account: Int?
        var amount: Int?
        var date: Int?

        /// Upstream's `Object.values()` order. Load-bearing: `merge` pairs the
        /// old and new sets positionally, so reordering this silently writes a
        /// payee into the account slot.
        var ordered: [Int?] { [payee, account, amount, date] }
    }

    /// Port of `extractScheduleConds`. Field fallbacks match upstream: a rule
    /// may name the payee `description` and the account `acct` (the internal
    /// schema names), and the public name wins when both are present.
    static func extract(_ conditions: [[String: Any]]) -> Indices {
        func find(ops: Set<String>, fields: [String]) -> Int? {
            for field in fields {
                if let index = conditions.firstIndex(where: {
                    ($0["op"] as? String).map(ops.contains) == true
                        && $0["field"] as? String == field
                }) {
                    return index
                }
            }
            return nil
        }

        return Indices(
            payee: find(ops: ["is"], fields: ["payee", "description"]),
            account: find(ops: ["is"], fields: ["account", "acct"]),
            amount: find(ops: ["is", "isapprox", "isbetween"], fields: ["amount"]),
            date: find(ops: ["is", "isapprox"], fields: ["date"]))
    }

    /// Port of `updateScheduleConditions`: the four conditions a schedule
    /// owns, built from the form.
    ///
    /// An existing condition keeps its op and any extra keys and only takes a
    /// new value — so a schedule the web set to an exact date stays exact
    /// after an edit here. Amount is the exception and is rewritten whole,
    /// because the form owns its operator.
    static func build(
        fields: ScheduleFormFields,
        existing: [[String: Any]]
    ) throws -> [[String: Any]] {
        guard let date = fields.date else { throw ScheduleWriteError.dateRequired }
        guard let amount = fields.amount else { throw ScheduleWriteError.amountRequired }

        let indices = extract(existing)

        func update(
            _ index: Int?,
            op: String,
            field: String,
            value: Any?
        ) -> [String: Any]? {
            if let index {
                var condition = existing[index]
                condition["value"] = value ?? NSNull()
                return condition
            }
            // A payee condition is written even when empty — upstream creates
            // it unconditionally so the slot exists for a later edit.
            guard value != nil || field == "payee" else { return nil }
            return ["op": op, "field": field, "value": value ?? NSNull()]
        }

        return [
            update(indices.payee, op: "is", field: "payee", value: fields.payeeId),
            update(indices.account, op: "is", field: "account", value: fields.accountId),
            update(indices.date, op: "isapprox", field: "date", value: dateValue(date)),
            // Never merged: the operator is part of what the form edits.
            ["op": fields.amountOp.rawValue, "field": "amount", "value": amountValue(amount)],
        ].compactMap { $0 }
    }

    /// Port of `updateConditions`: fold the four schedule conditions into the
    /// rule's full condition array.
    ///
    /// Conditions the schedule does not own are left exactly where they are —
    /// this is what keeps a schedule that was customised on the web ("edit as
    /// rule") intact after an edit from the phone.
    static func merge(
        existing: [[String: Any]],
        scheduleConditions: [[String: Any]]
    ) -> [[String: Any]] {
        let oldSlots = extract(existing).ordered
        let newSlots = extract(scheduleConditions).ordered

        var result = existing
        var appended: [[String: Any]] = []

        for (slot, newIndex) in newSlots.enumerated() {
            guard let newIndex else { continue }
            let replacement = scheduleConditions[newIndex]
            if let oldIndex = oldSlots[slot] {
                result[oldIndex] = replacement
            } else {
                appended.append(replacement)
            }
        }

        return result + appended
    }

    /// Port of `updateActions`: keep a plain `set amount` action aligned with
    /// the amount condition.
    ///
    /// Posting a scheduled transaction runs the rule, so an action left at the
    /// old amount would quietly overwrite the edited one. Templated and
    /// formula actions compute their own value and are never touched, and
    /// `set-split-amount` is excluded by the op check.
    ///
    /// Returns nil when nothing changed, so the caller can skip the write.
    static func syncedActions(
        conditions: [[String: Any]],
        actions: [[String: Any]]
    ) -> [[String: Any]]? {
        guard let amountIndex = extract(conditions).amount else { return nil }
        let amount = scheduledAmount(conditions[amountIndex]["value"])

        var updated = actions
        var changed = false
        for (index, action) in actions.enumerated() {
            guard action["op"] as? String == "set",
                  action["field"] as? String == "amount"
            else { continue }
            let options = action["options"] as? [String: Any]
            guard options?["template"] == nil, options?["formula"] == nil else { continue }
            guard (action["value"] as? NSNumber)?.intValue != amount else { continue }
            updated[index]["value"] = amount
            changed = true
        }
        return changed ? updated : nil
    }

    /// JSON paths for the local `schedules_json_paths` cache — upstream's
    /// `onRuleUpdate`.
    static func jsonPaths(
        for conditions: [[String: Any]]
    ) -> (payee: String?, account: String?, amount: String?, date: String?) {
        let indices = extract(conditions)
        func path(_ index: Int?) -> String? { index.map { "$[\($0)]" } }
        return (path(indices.payee), path(indices.account),
                path(indices.amount), path(indices.date))
    }

    // MARK: - Value conversion

    /// Port of `getScheduledAmount`, reading a raw condition value.
    static func scheduledAmount(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let range = value as? [String: Any],
           let num1 = (range["num1"] as? NSNumber)?.intValue,
           let num2 = (range["num2"] as? NSNumber)?.intValue {
            return ScheduledAmount.range(num1, num2).postAmount
        }
        return 0
    }

    static func amountValue(_ amount: ScheduledAmount) -> Any {
        switch amount {
        case .fixed(let cents): cents
        case .range(let num1, let num2): ["num1": num1, "num2": num2]
        }
    }

    static func dateValue(_ date: ScheduleDateCondition) -> Any {
        switch date {
        case .fixed(let day): day.iso
        case .recurring(let config): config.jsonObject
        }
    }

    /// The next occurrence a date condition implies, port of loot-core
    /// `getNextDate`. A one-off date is returned as-is even when it is in the
    /// past — upstream does the same, and the status engine renders that as
    /// `missed` rather than silently moving it.
    static func nextDate(
        for date: ScheduleDateCondition,
        from today: DayDate = .today()
    ) -> DayDate? {
        switch date {
        case .fixed(let day):
            return day
        case .recurring(let config):
            return ScheduleRecurrence.nextOccurrence(config: config, onOrAfter: today)
        }
    }

    /// Compare two conditions ignoring the transient `type` key, which
    /// upstream strips before comparing. Drives the "did the account or date
    /// change?" test that decides whether the next date is recomputed.
    static func conditionsEqual(_ lhs: [String: Any]?, _ rhs: [String: Any]?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let left?, let right?):
            var a = left, b = right
            a.removeValue(forKey: "type")
            b.removeValue(forKey: "type")
            return NSDictionary(dictionary: a).isEqual(to: b)
        default:
            return false
        }
    }

    static func condition(at index: Int?, in conditions: [[String: Any]]) -> [String: Any]? {
        guard let index, conditions.indices.contains(index) else { return nil }
        return conditions[index]
    }

    // MARK: - JSON

    static func parse(_ json: String?) -> [[String: Any]] {
        guard let json, let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return [] }
        return parsed as? [[String: Any]] ?? []
    }

    /// Sorted keys keep the output deterministic, which matters for tests.
    /// Key order inside a JSON object is not significant to any reader; ARRAY
    /// order is, and is preserved.
    static func serialize(_ value: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
