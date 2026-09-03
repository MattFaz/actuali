
import Foundation

/// Human-readable text for a schedule's recurrence and status
enum ScheduleDescription {

    // MARK: - Status

    static func statusLabel(_ status: ScheduleStatus, locale: Locale = .autoupdatingCurrent) -> String {
        switch status {
        case .completed: String(localized: "Completed", locale: locale)
        case .paid: String(localized: "Paid", locale: locale)
        case .due: String(localized: "Due", locale: locale)
        case .upcoming: String(localized: "Upcoming", locale: locale)
        case .missed: String(localized: "Missed", locale: locale)
        case .scheduled: String(localized: "Scheduled", locale: locale)
        }
    }

    // MARK: - Date condition

    /// One-line summary of a schedule's date condition, for the list row.
    static func dateSummary(_ condition: ScheduleDateCondition?, locale: Locale = .autoupdatingCurrent) -> String {
        switch condition {
        case .fixed(let day): Self.mediumDate(day, locale: locale)
        case .recurring(let config): recurring(config, locale: locale)
        case .unsupported: String(localized: "Unsupported repeat", locale: locale)
        case nil: String(localized: "No date", locale: locale)
        }
    }

    // MARK: - Recurrence

    static func recurring(_ config: RecurConfig, locale: Locale = .autoupdatingCurrent) -> String {
        let interval = max(1, config.interval)

        var endSuffix = ""
        switch config.endMode {
        case "after_n_occurrences":
            let count = config.endOccurrences ?? 1
            endSuffix = count == 1
                ? String(localized: "once", locale: locale)
                : String(format: String(localized: "%lld times", locale: locale), Int64(count))
        case "on_date":
            if let end = config.endDate {
                endSuffix = String(format: String(localized: "until %@", locale: locale), mediumDate(end, locale: locale))
            }
        default:
            break
        }

        let weekendSuffix = config.skipWeekend
            ? (config.weekendSolveMode == "after"
                ? String(localized: "(after weekend)", locale: locale)
                : String(localized: "(before weekend)", locale: locale))
            : ""

        var suffix = ""
        if !endSuffix.isEmpty { suffix += ", \(endSuffix)" }
        if !weekendSuffix.isEmpty { suffix += " \(weekendSuffix)" }

        let body: String
        switch config.frequency {
        case .daily:
            body = interval != 1
                ? String(format: String(localized: "Every %lld days", locale: locale), Int64(interval))
                : String(localized: "Every day", locale: locale)
        case .weekly:
            let day = weekdayName(config.start.weekday, locale: locale)
            body = interval != 1
                ? String(format: String(localized: "Every %lld weeks on %@", locale: locale), Int64(interval), day)
                : String(format: String(localized: "Every week on %@", locale: locale), day)
        case .monthly:
            let range = monthlyRange(config, locale: locale)
            if range.isEmpty {
                let day = ordinal(config.start.day, locale: locale)
                body = interval != 1
                    ? String(format: String(localized: "Every %lld months on the %@", locale: locale), Int64(interval), day)
                    : String(format: String(localized: "Every month on the %@", locale: locale), day)
            } else {
                body = interval != 1
                    ? String(format: String(localized: "Every %lld months on %@", locale: locale), Int64(interval), range)
                    : String(format: String(localized: "Every month on %@", locale: locale), range)
            }
        case .yearly:
            let day = String(format: String(localized: "%@ %@", locale: locale),
                             shortMonthName(config.start.month, locale: locale),
                             ordinal(config.start.day, locale: locale))
            body = interval != 1
                ? String(format: String(localized: "Every %lld years on %@", locale: locale), Int64(interval), day)
                : String(format: String(localized: "Every year on %@", locale: locale), day)
        }

        return (body + suffix).trimmingCharacters(in: .whitespaces)
    }

    /// The "15th and last day" / "1st and 3rd Monday" fragment. Empty when the
    /// config carries no patterns (a plain monthly recurrence).
    private static func monthlyRange(_ config: RecurConfig, locale: Locale = .autoupdatingCurrent) -> String {
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
                return pattern.value == -1
                    ? String(localized: "last day", locale: locale)
                    : ordinal(pattern.value, locale: locale)
            }
            let dayName = isSameDay ? "" : " " + weekdayName(forCode: pattern.type, locale: locale)
            return pattern.value == -1
                ? String(localized: "last", locale: locale) + dayName
                : ordinal(pattern.value, locale: locale) + dayName
        }

        var range: String
        if parts.count > 2 {
            range = parts.dropLast().joined(separator: ", ")
                + String(localized: ", and ", locale: locale)
                + (parts.last ?? "")
        } else {
            range = parts.joined(separator: String(localized: " and ", locale: locale))
        }
        if isSameDay {
            range += " " + weekdayName(forCode: first.type, locale: locale)
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
    static func ordinal(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        ordinalFormatter.locale = locale
        return ordinalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 1 = Sunday ... 7 = Saturday, matching `DayDate.weekday`.
    static func weekdayName(_ weekday: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        let names = formatter.weekdaySymbols ?? []
        let index = weekday - 1
        return names.indices.contains(index) ? names[index] : ""
    }

    /// "SU".."SA" — the pattern-type codes used in a recurrence config.
    static func weekdayName(forCode code: String, locale: Locale = .autoupdatingCurrent) -> String {
        let values = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        return values[code].map { weekdayName($0, locale: locale) } ?? code
    }

    static func shortMonthName(_ month: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        let names = formatter.shortMonthSymbols ?? []
        let index = month - 1
        return names.indices.contains(index) ? names[index] : ""
    }

    /// Locale-formatted medium date, matching how transaction rows read.
    static func mediumDate(_ day: DayDate, locale: Locale = .autoupdatingCurrent) -> String {
        Transaction.date(fromYYYYMMDD: day.yyyymmdd)
            .formatted(.dateTime.locale(locale).day().month(.abbreviated).year())
    }
}
