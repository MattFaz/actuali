
import Foundation

/// Human-readable text for a schedule's recurrence and status
enum ScheduleDescription {

    // MARK: - Status

    static func statusLabel(_ status: ScheduleStatus) -> String {
        switch status {
        case .completed: "Completed"
        case .paid: "Paid"
        case .due: "Due"
        case .upcoming: "Upcoming"
        case .missed: "Missed"
        case .scheduled: "Scheduled"
        }
    }

    // MARK: - Date condition

    /// One-line summary of a schedule's date condition, for the list row.
    static func dateSummary(_ condition: ScheduleDateCondition?) -> String {
        switch condition {
        case .fixed(let day): Self.mediumDate(day)
        case .recurring(let config): recurring(config)
        case nil: "No date"
        }
    }

    // MARK: - Recurrence

    static func recurring(_ config: RecurConfig) -> String {
        let interval = max(1, config.interval)

        var endSuffix = ""
        switch config.endMode {
        case "after_n_occurrences":
            let count = config.endOccurrences ?? 1
            endSuffix = count == 1 ? "once" : "\(count) times"
        case "on_date":
            if let end = config.endDate { endSuffix = "until \(mediumDate(end))" }
        default:
            break
        }

        let weekendSuffix = config.skipWeekend
            ? (config.weekendSolveMode == "after" ? "(after weekend)" : "(before weekend)")
            : ""

        var suffix = ""
        if !endSuffix.isEmpty { suffix += ", \(endSuffix)" }
        if !weekendSuffix.isEmpty { suffix += " \(weekendSuffix)" }

        let body: String
        switch config.frequency {
        case .daily:
            body = interval != 1 ? "Every \(interval) days" : "Every day"
        case .weekly:
            let day = weekdayName(config.start.weekday)
            body = interval != 1 ? "Every \(interval) weeks on \(day)" : "Every week on \(day)"
        case .monthly:
            let range = monthlyRange(config)
            if range.isEmpty {
                let day = ordinal(config.start.day)
                body = interval != 1
                    ? "Every \(interval) months on the \(day)"
                    : "Every month on the \(day)"
            } else {
                body = interval != 1
                    ? "Every \(interval) months on the \(range)"
                    : "Every month on the \(range)"
            }
        case .yearly:
            let day = "\(shortMonthName(config.start.month)) \(ordinal(config.start.day))"
            body = interval != 1 ? "Every \(interval) years on \(day)" : "Every year on \(day)"
        }

        return (body + suffix).trimmingCharacters(in: .whitespaces)
    }

    /// The "15th and last day" / "1st and 3rd Monday" fragment. Empty when the
    /// config carries no patterns (a plain monthly recurrence).
    private static func monthlyRange(_ config: RecurConfig) -> String {
        guard !config.patterns.isEmpty else { return "" }

        // Weekday patterns sort ahead of day-of-month patterns, then by value.
        // `-1` means "last" and is pulled out first so it always lands at the
        // end rather than sorting to the front as the smallest number.
        let sorted = config.patterns
            .filter { $0.value != -1 }
            .sorted { lhs, rhs in
                let lhsIsDay = lhs.type == "day" ? 1 : 0
                let rhsIsDay = rhs.type == "day" ? 1 : 0
                if lhsIsDay != rhsIsDay { return lhsIsDay < rhsIsDay }
                return lhs.value < rhs.value
            }
        let patterns = sorted + config.patterns.filter { $0.value == -1 }
        guard let first = patterns.first else { return "" }

        // When every pattern names the same weekday ("1st and 3rd Monday"),
        // the weekday is said once at the end instead of after each ordinal.
        let uniqueTypes = Set(patterns.map(\.type))
        let isSameDay = uniqueTypes.count == 1 && !uniqueTypes.contains("day")

        let parts: [String] = patterns.map { pattern in
            if pattern.type == "day" {
                return pattern.value == -1 ? "last day" : ordinal(pattern.value)
            }
            let dayName = isSameDay ? "" : " " + weekdayName(forCode: pattern.type)
            return pattern.value == -1 ? "last" + dayName : ordinal(pattern.value) + dayName
        }

        var range: String
        if parts.count > 2 {
            range = parts.dropLast().joined(separator: ", ") + ", and " + (parts.last ?? "")
        } else {
            range = parts.joined(separator: " and ")
        }
        if isSameDay {
            range += " " + weekdayName(forCode: first.type)
        }
        return range
    }

    // MARK: - Formatting helpers

    private static let ordinalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter
    }()

    /// "1st", "15th" — upstream's `makeNumberSuffix`.
    static func ordinal(_ value: Int) -> String {
        ordinalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 1 = Sunday ... 7 = Saturday, matching `DayDate.weekday`.
    static func weekdayName(_ weekday: Int) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday",
                     "Thursday", "Friday", "Saturday"]
        let index = weekday - 1
        return names.indices.contains(index) ? names[index] : ""
    }

    /// "SU".."SA" — the pattern-type codes used in a recurrence config.
    static func weekdayName(forCode code: String) -> String {
        let names = ["SU": "Sunday", "MO": "Monday", "TU": "Tuesday",
                     "WE": "Wednesday", "TH": "Thursday", "FR": "Friday",
                     "SA": "Saturday"]
        return names[code] ?? code
    }

    static func shortMonthName(_ month: Int) -> String {
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let index = month - 1
        return names.indices.contains(index) ? names[index] : ""
    }

    /// Locale-formatted medium date, matching how transaction rows read.
    static func mediumDate(_ day: DayDate) -> String {
        Transaction.date(fromYYYYMMDD: day.yyyymmdd)
            .formatted(date: .abbreviated, time: .omitted)
    }
}
