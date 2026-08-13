import Foundation

/// Parsed schedule recurrence config, mirroring loot-core's `_conditions.date` recurring value.
struct RecurConfig: Equatable {
    enum Frequency: String { case daily, weekly, monthly, yearly }
    struct Pattern: Equatable { let type: String; let value: Int }   // type: "day" | "SU".."SA"

    let frequency: Frequency
    let interval: Int
    let start: DayDate
    let patterns: [Pattern]
    let skipWeekend: Bool
    let weekendSolveMode: String        // "before" | "after"
    let endMode: String                 // unknown values behave as "never" (matches JS switch default)
    let endOccurrences: Int?
    let endDate: DayDate?

    init?(json: [String: Any]) {
        guard let f = json["frequency"] as? String, let freq = Frequency(rawValue: f),
              let startStr = json["start"] as? String, let start = DayDate(iso: startStr)
        else { return nil }
        frequency = freq
        self.start = start
        interval = max(1, json["interval"] as? Int ?? 1)
        if let raw = json["patterns"] as? [[String: Any]] {
            var parsed: [Pattern] = []
            for p in raw {
                guard let t = p["type"] as? String, let v = p["value"] as? Int, v != 0,
                      t == "day"
                        ? abs(v) <= 31
                        : (["SU", "MO", "TU", "WE", "TH", "FR", "SA"].contains(t) && abs(v) <= 5)
                else { return nil }   // malformed pattern → whole config unsupported
                parsed.append(Pattern(type: t, value: v))
            }
            patterns = parsed
        } else { patterns = [] }
        skipWeekend = json["skipWeekend"] as? Bool ?? false
        weekendSolveMode = json["weekendSolveMode"] as? String ?? "after"
        endMode = json["endMode"] as? String ?? "never"
        endOccurrences = json["endOccurrences"] as? Int
        endDate = (json["endDate"] as? String).flatMap { DayDate(iso: $0) }
        // A bounded endMode missing its bound must not silently degrade to "recur forever".
        if endMode == "on_date", endDate == nil { return nil }
        if endMode == "after_n_occurrences", (endOccurrences ?? 0) <= 0 { return nil }
    }
}

/// Pure-Swift port of loot-core's schedule recurrence math (`getNextDate`).
enum ScheduleRecurrence {
    private static let periodCap = 20_000
    private static let weekdayNumber: [String: Int] = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    /// Port of loot-core getNextDate: first occurrence on/after `target`, falling back
    /// to the LAST occurrence if the schedule already ended. Weekend solve applies to
    /// the final result only (may move it before `target`).
    static func nextOccurrence(config: RecurConfig, onOrAfter target: DayDate) -> DayDate? {
        let raw = rawNext(config: config, onOrAfter: target) ?? rawLast(config: config)
        guard var date = raw else { return nil }
        if config.skipWeekend, date.isWeekend {
            date = config.weekendSolveMode == "before" ? previousFriday(from: date) : nextMonday(from: date)
        }
        return date
    }

    // Monthly day-patterns and weekday-patterns are SEPARATE unioned rrules,
    // each carrying the full count/endDate independently (matches recurConfigToRSchedule).
    private struct SubRule {
        let config: RecurConfig
        let kind: Kind
        enum Kind { case plain; case daysOfMonth([Int]); case weekdays([(weekday: Int, nth: Int)]) }
    }

    private static func subRules(_ c: RecurConfig) -> [SubRule] {
        guard c.frequency == .monthly, !c.patterns.isEmpty else { return [SubRule(config: c, kind: .plain)] }
        var rules: [SubRule] = []
        let days = c.patterns.filter { $0.type == "day" }.map(\.value)
        let weekdays = c.patterns.filter { $0.type != "day" }.map { (weekday: weekdayNumber[$0.type]!, nth: $0.value) }
        if !days.isEmpty { rules.append(SubRule(config: c, kind: .daysOfMonth(days))) }
        if !weekdays.isEmpty { rules.append(SubRule(config: c, kind: .weekdays(weekdays))) }
        return rules
    }

    private static func rawNext(config: RecurConfig, onOrAfter target: DayDate) -> DayDate? {
        subRules(config).compactMap { firstOccurrence(of: $0, where: { $0 >= target }) }.min()
    }

    private static func rawLast(config: RecurConfig) -> DayDate? {
        subRules(config).compactMap { lastOccurrence(of: $0) }.max()
    }

    private static func firstOccurrence(of rule: SubRule, where predicate: (DayDate) -> Bool) -> DayDate? {
        var count = 0
        var result: DayDate?
        enumerate(rule) { date in
            count += 1
            if let cap = rule.config.endOccurrences, rule.config.endMode == "after_n_occurrences", count > cap { return false }
            if let end = rule.config.endDate, rule.config.endMode == "on_date", date > end { return false }
            if predicate(date) { result = date; return false }
            return true
        }
        return result
    }

    private static func lastOccurrence(of rule: SubRule) -> DayDate? {
        guard rule.config.endMode == "after_n_occurrences" || rule.config.endMode == "on_date" else { return nil }
        var count = 0
        var last: DayDate?
        enumerate(rule) { date in
            if let end = rule.config.endDate, rule.config.endMode == "on_date", date > end { return false }
            count += 1
            if let cap = rule.config.endOccurrences, rule.config.endMode == "after_n_occurrences", count > cap { return false }
            last = date
            return true
        }
        return last
    }

    /// Yields occurrences chronologically; body returns false to stop.
    private static func enumerate(_ rule: SubRule, _ body: (DayDate) -> Bool) {
        let c = rule.config
        switch c.frequency {
        case .daily:
            var d = c.start
            for _ in 0..<periodCap {
                if !body(d) { return }
                d = d.adding(days: c.interval)
            }
        case .weekly:
            var d = c.start
            for _ in 0..<periodCap {
                if !body(d) { return }
                d = d.adding(days: 7 * c.interval)
            }
        case .yearly:
            for k in 0..<periodCap {
                let y = c.start.year + k * c.interval
                guard c.start.day <= DayDate.lastDay(year: y, month: c.start.month) else { continue }
                if !body(DayDate(year: y, month: c.start.month, day: c.start.day)) { return }
            }
        case .monthly:
            for k in 0..<periodCap {
                let totalMonths = (c.start.month - 1) + k * c.interval
                let y = c.start.year + totalMonths / 12
                let m = totalMonths % 12 + 1
                let lastDay = DayDate.lastDay(year: y, month: m)
                var candidates: [DayDate] = []
                switch rule.kind {
                case .plain:
                    if c.start.day <= lastDay { candidates.append(DayDate(year: y, month: m, day: c.start.day)) }
                case .daysOfMonth(let days):
                    for v in days {
                        let day = v > 0 ? v : lastDay + 1 + v
                        if (1...lastDay).contains(day) { candidates.append(DayDate(year: y, month: m, day: day)) }
                    }
                case .weekdays(let pairs):
                    for (weekday, nth) in pairs {
                        if let d = nthWeekday(year: y, month: m, weekday: weekday, nth: nth) { candidates.append(d) }
                    }
                }
                for d in candidates.sorted() where d >= c.start {
                    if !body(d) { return }
                }
            }
        }
    }

    private static func nthWeekday(year: Int, month: Int, weekday: Int, nth: Int) -> DayDate? {
        let lastDay = DayDate.lastDay(year: year, month: month)
        if nth > 0 {
            let first = DayDate(year: year, month: month, day: 1)
            let offset = (weekday - first.weekday + 7) % 7
            let day = 1 + offset + (nth - 1) * 7
            return day <= lastDay ? DayDate(year: year, month: month, day: day) : nil
        } else {
            let last = DayDate(year: year, month: month, day: lastDay)
            let offset = (last.weekday - weekday + 7) % 7
            let day = lastDay - offset + (nth + 1) * 7
            return day >= 1 ? DayDate(year: year, month: month, day: day) : nil
        }
    }

    private static func nextMonday(from d: DayDate) -> DayDate {
        var x = d
        while x.weekday != 2 { x = x.adding(days: 1) }
        return x
    }

    private static func previousFriday(from d: DayDate) -> DayDate {
        var x = d
        while x.weekday != 6 { x = x.adding(days: -1) }
        return x
    }
}
