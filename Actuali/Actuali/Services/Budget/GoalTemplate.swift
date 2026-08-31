import Foundation

/// One goal-template line for a category — the parsed form of a `#template` /
/// `#goal` note line, and the unit stored in `categories.goal_def` (a JSON
/// array of these). Mirrors loot-core's `Template` union
/// (types/models/templates.ts); one struct with optional fields instead of a
/// Swift enum so unknown/partial JSON written by other clients (including the
/// web's template-editor UI, which also emits `refill` and `limit` types)
/// round-trips without loss.
struct GoalTemplate: Equatable, Sendable {
    enum Directive: String, Sendable {
        case template, goal, error
    }

    enum Kind: String, Sendable {
        case percentage, periodic, by, spend, simple, schedule, average,
             copy, remainder, refill, goal, limit, error
    }

    enum LimitPeriod: String, Sendable {
        case daily, weekly, monthly
    }

    struct Limit: Equatable, Sendable {
        var amount: Double
        var hold: Bool
        var period: LimitPeriod
        var start: String? // "YYYY-MM-DD", weekly only
    }

    enum PeriodUnit: String, Sendable {
        case day, week, month, year
    }

    struct Period: Equatable, Sendable {
        var period: PeriodUnit
        var amount: Int
    }

    enum AdjustmentType: String, Sendable {
        case percent, fixed
    }

    var type: Kind
    var directive: Directive
    /// 0 for a bare `#template`, N for `#template-N`. nil where upstream
    /// stores null (remainder, goal, limit).
    var priority: Int?

    // Amounts are whole currency units (e.g. 50.5 dollars), matching the JSON
    // upstream stores — the engine converts to cents when it runs.
    var amount: Double?
    var monthly: Double? // simple; nil = limit-only line
    var limit: Limit?
    var percent: Double? // percentage
    var previous: Bool? // percentage: "of previous"
    var category: String? // percentage income source (name, id, or special)
    var period: Period? // periodic
    var starting: String? // periodic: "YYYY-MM-DD"
    var month: String? // by/spend target: "YYYY-MM"
    var annual: Bool? // by/spend repeat every year(s) vs month(s)
    var repeatCount: Int? // by/spend repeat interval ("repeat" in JSON)
    var from: String? // spend start: "YYYY-MM"
    var name: String? // schedule name
    var scheduleId: String? // schedule id (UI-managed templates)
    var full: Bool? // schedule: budget in full the month it's due
    var adjustment: Double? // schedule/average increase/decrease
    var adjustmentType: AdjustmentType?
    var numMonths: Int? // average
    var lookBack: Int? // copy
    var weight: Double? // remainder
    var line: String? // error: the raw note line
    var error: String? // error: parser message
    var description: String? // note lines directly above the template line

    init(type: Kind, directive: Directive, priority: Int? = nil) {
        self.type = type
        self.directive = directive
        self.priority = priority
    }
}

// MARK: - goal_def JSON

extension GoalTemplate {
    /// Decode a `goal_def` column value. Unknown `type`/`directive` strings
    /// become error templates rather than being dropped, so a template written
    /// by a newer client blocks the category's apply (matching how upstream
    /// surfaces malformed lines) instead of silently half-applying.
    static func decodeArray(fromJSON json: String) -> [GoalTemplate]? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let array = parsed as? [[String: Any]] else { return nil }
        return array.map { GoalTemplate(jsonObject: $0) }
    }

    static func encodeArray(_ templates: [GoalTemplate]) -> String? {
        let objects = templates.map(\.jsonObject)
        guard let data = try? JSONSerialization.data(
            withJSONObject: objects, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    init(jsonObject: [String: Any]) {
        func double(_ key: String) -> Double? {
            (jsonObject[key] as? NSNumber)?.doubleValue
        }
        func int(_ key: String) -> Int? {
            (jsonObject[key] as? NSNumber)?.intValue
        }
        func bool(_ key: String) -> Bool? {
            guard let value = jsonObject[key], !(value is NSNull) else { return nil }
            if let number = value as? NSNumber { return number.boolValue }
            return nil
        }
        func string(_ key: String) -> String? {
            jsonObject[key] as? String
        }

        let kind = string("type").flatMap(Kind.init(rawValue:))
        let directive = string("directive").flatMap(Directive.init(rawValue:))
        if let kind, let directive {
            self.init(type: kind, directive: directive, priority: int("priority"))
        } else {
            self.init(type: .error, directive: .error)
            self.line = string("line") ?? (string("type") ?? "unknown template")
            self.error = string("error") ?? "Unrecognized template type"
            self.description = string("description")
            return
        }

        amount = double("amount")
        monthly = double("monthly")
        if let limitObject = jsonObject["limit"] as? [String: Any],
           let limitAmount = (limitObject["amount"] as? NSNumber)?.doubleValue {
            limit = Limit(
                amount: limitAmount,
                hold: (limitObject["hold"] as? NSNumber)?.boolValue ?? false,
                period: (limitObject["period"] as? String)
                    .flatMap(LimitPeriod.init(rawValue:)) ?? .monthly,
                start: limitObject["start"] as? String)
        } else if kind == .limit {
            // The UI's LimitTemplate stores its fields at the top level.
            limit = Limit(
                amount: amount ?? 0,
                hold: bool("hold") ?? false,
                period: string("period").flatMap(LimitPeriod.init(rawValue:)) ?? .monthly,
                start: string("start"))
        }
        percent = double("percent")
        previous = bool("previous")
        category = string("category")
        if let periodObject = jsonObject["period"] as? [String: Any],
           let unit = (periodObject["period"] as? String).flatMap(PeriodUnit.init(rawValue:)),
           let periodAmount = (periodObject["amount"] as? NSNumber)?.intValue {
            period = Period(period: unit, amount: periodAmount)
        }
        starting = string("starting")
        month = string("month")
        annual = bool("annual")
        repeatCount = int("repeat")
        from = string("from")
        name = string("name")
        scheduleId = string("scheduleId")
        full = bool("full")
        adjustment = double("adjustment")
        adjustmentType = string("adjustmentType").flatMap(AdjustmentType.init(rawValue:))
        numMonths = int("numMonths")
        lookBack = int("lookBack")
        weight = double("weight")
        line = string("line")
        error = string("error")
        description = string("description")
    }

    /// The JSON object upstream's `JSON.parse(goal_def)` readers expect.
    /// Integral doubles serialize as plain integers (NSNumber picks the
    /// shortest form), matching what peggy's `+amount` produces in JS.
    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "type": type.rawValue,
            "directive": directive.rawValue,
        ]
        // Upstream's parser emits explicit nulls for priority on
        // remainder/goal lines; readers null-check rather than key-check, so
        // always carrying the key is safe and closer to the source format.
        object["priority"] = priority.map { $0 as Any } ?? NSNull()
        func number(_ value: Double) -> NSNumber {
            value == value.rounded() && abs(value) < 1e15
                ? NSNumber(value: Int64(value)) : NSNumber(value: value)
        }
        if let amount { object["amount"] = number(amount) }
        if let monthly { object["monthly"] = number(monthly) }
        if type == .simple, monthly == nil { object["monthly"] = NSNull() }
        if let limit, type == .limit {
            object["amount"] = number(limit.amount)
            object["hold"] = limit.hold
            object["period"] = limit.period.rawValue
            if let start = limit.start { object["start"] = start }
        } else if let limit {
            var limitObject: [String: Any] = [
                "amount": number(limit.amount),
                "hold": limit.hold,
                "period": limit.period.rawValue,
            ]
            limitObject["start"] = limit.start.map { $0 as Any } ?? NSNull()
            object["limit"] = limitObject
        } else if type == .simple || type == .periodic || type == .remainder {
            object["limit"] = NSNull()
        }
        if let percent { object["percent"] = number(percent) }
        if let previous { object["previous"] = previous }
        if let category { object["category"] = category }
        if let period {
            object["period"] = ["period": period.period.rawValue, "amount": period.amount]
        }
        if let starting { object["starting"] = starting }
        if let month { object["month"] = month }
        if let annual { object["annual"] = annual }
        if let repeatCount { object["repeat"] = repeatCount }
        if type == .spend || type == .by {
            object["from"] = from.map { $0 as Any } ?? NSNull()
        }
        if let name { object["name"] = name }
        if let scheduleId { object["scheduleId"] = scheduleId }
        if let full { object["full"] = full }
        if let adjustment { object["adjustment"] = number(adjustment) }
        if let adjustmentType { object["adjustmentType"] = adjustmentType.rawValue }
        if let numMonths { object["numMonths"] = numMonths }
        if let lookBack { object["lookBack"] = lookBack }
        if let weight { object["weight"] = number(weight) }
        if let line { object["line"] = line }
        if let error { object["error"] = error }
        if let description { object["description"] = description }
        return object
    }
}
