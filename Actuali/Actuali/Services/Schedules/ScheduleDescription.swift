
import Foundation

/// Human-readable text for a schedule's recurrence and status
enum ScheduleDescription {

    // MARK: - Status

    static func statusLabel(_ status: ScheduleStatus) -> String {
        switch status {
        case .completed: String(localized: "Completed")
        case .paid: String(localized: "Paid")
        case .due: String(localized: "Due")
        case .upcoming: String(localized: "Upcoming")
        case .missed: String(localized: "Missed")
        case .scheduled: String(localized: "Scheduled")
        }
    }

    // MARK: - Date condition

    /// One-line summary of a schedule's date condition, for the list row.
    static func dateSummary(_ condition: ScheduleDateCondition?) -> String {
        switch condition {
        case .fixed(let day): Self.mediumDate(day)
        case .recurring(let config): recurring(config)
        case .unsupported: String(localized: "Unsupported repeat")
        case nil: String(localized: "No date")
        }
    }

    // MARK: - Recurrence

    static func recurring(_ config: RecurConfig) -> String {
        let interval = max(1, config.interval)

        var endSuffix = ""
        switch config.endMode {
        case "after_n_occurrences":
            let count = config.endOccurrences ?? 1
            endSuffix = count == 1
                ? String(localized: "once")
                : String(format: String(localized: "%lld times"), Int64(count))
        case "on_date":
            if let end = config.endDate {
                endSuffix = String(format: String(localized: "until %@"), mediumDate(end))
            }
        default:
            break
        }

        let weekendSuffix = config.skipWeekend
            ? (config.weekendSolveMode == "after" ? String(localized: "(after weekend)") : String(localized: "(before weekend)"))
            : ""

        var suffix = ""
        if !endSuffix.isEmpty { suffix += String(format: String(localized: ", %@"), endSuffix) }
        if !weekendSuffix.isEmpty { suffix += " \(weekendSuffix)" }

        let body: String
        switch config.frequency {
        case .daily:
            body = interval != 1
                ? String(format: String(localized: "Every %lld days"), Int64(interval))
                : String(localized: "Every day")
        case .weekly:
            let day = weekdayName(config.start.weekday)
            body = interval != 1
                ? String(format: String(localized: "Every %lld weeks on %@"), Int64(interval), day)
                : String(format: String(localized: "Every week on %@"), day)
        case .monthly:
            let range = monthlyRange(config)
            if range.isEmpty {
                let day = ordinal(config.start.day)
                body = interval != 1
                    ? String(format: String(localized: "Every %lld months on the %@"), Int64(interval), day)
                    : String(format: String(localized: "Every month on the %@"), day)
            } else {
                body = interval != 1
                    ? String(format: String(localized: "Every %lld months on the %@"), Int64(interval), range)
                    : String(format: String(localized: "Every month on the %@"), range)
            }
        case .yearly:
            let day = Transaction.date(fromYYYYMMDD: config.start.yyyymmdd)
                .formatted(.dateTime.month(.abbreviated).day(.defaultDigits))
            body = interval != 1
                ? String(format: String(localized: "Every %lld years on %@"), Int64(interval), day)
                : String(format: String(localized: "Every year on %@"), day)
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
                return pattern.value == -1 ? String(localized: "last day") : ordinal(pattern.value)
            }
            let dayName = isSameDay ? "" : " " + weekdayName(forCode: pattern.type)
            if pattern.value == -1 {
                return isSameDay
                    ? String(format: String(localized: "last %@"), weekdayName(forCode: pattern.type))
                    : String(localized: "last") + dayName
            }
            return ordinal(pattern.value) + dayName
        }

        var range: String
        if parts.count > 2 {
            range = parts.dropLast().joined(separator: ", ") + String(localized: ", and ") + (parts.last ?? "")
        } else {
            range = parts.joined(separator: String(localized: " and "))
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
    static func weekdayName(_ weekday: Int, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let names = calendar.weekdaySymbols
        let index = weekday - 1
        return names.indices.contains(index) ? names[index] : ""
    }

    /// "SU".."SA" — the pattern-type codes used in a recurrence config.
    static func weekdayName(forCode code: String, locale: Locale = .current) -> String {
        let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        return weekdays[code].map { weekdayName($0, locale: locale) } ?? code
    }

    static func shortMonthName(_ month: Int, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let names = calendar.shortMonthSymbols
        let index = month - 1
        return names.indices.contains(index) ? names[index] : ""
    }

    /// Locale-formatted medium date, matching how transaction rows read.
    static func mediumDate(_ day: DayDate) -> String {
        Transaction.date(fromYYYYMMDD: day.yyyymmdd)
            .formatted(date: .abbreviated, time: .omitted)
    }
}
