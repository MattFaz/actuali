
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
    static func dateSummary(
        _ condition: ScheduleDateCondition?,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> String {
        switch condition {
        case .fixed(let day): Self.mediumDate(day, locale: locale)
        case .recurring(let config): recurring(config, locale: locale, bundle: bundle)
        case .unsupported: ReportStrings.text("Unsupported repeat", locale: locale, bundle: bundle)
        case nil: ReportStrings.text("No date", locale: locale, bundle: bundle)
        }
    }

    // MARK: - Recurrence

    static func recurring(
        _ config: RecurConfig,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> String {
        let interval = max(1, config.interval)

        var endSuffix = ""
        switch config.endMode {
        case "after_n_occurrences":
            let count = config.endOccurrences ?? 1
            endSuffix = ReportStrings.localized("\(count) times", locale: locale, bundle: bundle)
        case "on_date":
            if let end = config.endDate {
                endSuffix = ReportStrings.localized("until \(mediumDate(end, locale: locale))", locale: locale, bundle: bundle)
            }
        default:
            break
        }

        let weekendSuffix = config.skipWeekend
            ? (config.weekendSolveMode == "after"
                ? ReportStrings.text("(after weekend)", locale: locale, bundle: bundle)
                : ReportStrings.text("(before weekend)", locale: locale, bundle: bundle))
            : ""

        var suffix = ""
        if !endSuffix.isEmpty { suffix += ReportStrings.localized(", \(endSuffix)", locale: locale, bundle: bundle) }
        if !weekendSuffix.isEmpty { suffix += " \(weekendSuffix)" }

        let body: String
        switch config.frequency {
        case .daily:
            body = ReportStrings.localized("Every \(interval) days", locale: locale, bundle: bundle)
        case .weekly:
            let day = weekdayName(config.start.weekday, locale: locale)
            body = ReportStrings.localized("Every \(interval) weeks on \(day)", locale: locale, bundle: bundle)
        case .monthly:
            let range = monthlyRange(config, locale: locale, bundle: bundle)
            if range.isEmpty {
                let day = ordinal(config.start.day, locale: locale)
                body = ReportStrings.localized("Every \(interval) months on the \(day)", locale: locale, bundle: bundle)
            } else {
                body = ReportStrings.localized("Every \(interval) months on the \(range)", locale: locale, bundle: bundle)
            }
        case .yearly:
            let day = Transaction.date(fromYYYYMMDD: config.start.yyyymmdd)
                .formatted(.dateTime.locale(locale).month(.abbreviated).day(.defaultDigits))
            body = ReportStrings.localized("Every \(interval) years on \(day)", locale: locale, bundle: bundle)
        }

        return (body + suffix).trimmingCharacters(in: .whitespaces)
    }

    /// The "15th and last day" / "1st and 3rd Monday" fragment. Empty when the
    /// config carries no patterns (a plain monthly recurrence).
    private static func monthlyRange(_ config: RecurConfig, locale: Locale, bundle: Bundle) -> String {
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
                    ? ReportStrings.text("last day", locale: locale, bundle: bundle)
                    : ordinal(pattern.value, locale: locale)
            }
            let dayName = isSameDay ? "" : " " + weekdayName(forCode: pattern.type, locale: locale)
            if pattern.value == -1 {
                return ReportStrings.text("last", locale: locale, bundle: bundle) + dayName
            }
            return ordinal(pattern.value, locale: locale) + dayName
        }

        var range: String
        if parts.count > 2 {
            range = parts.dropLast().joined(separator: ", ") + ReportStrings.text(", and ", locale: locale, bundle: bundle) + (parts.last ?? "")
        } else {
            range = parts.joined(separator: ReportStrings.text(" and ", locale: locale, bundle: bundle))
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
    static func ordinal(_ value: Int, locale: Locale = .current) -> String {
        ordinalFormatter.locale = locale
        return ordinalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
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
    static func mediumDate(_ day: DayDate, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.locale = locale
        return Transaction.date(fromYYYYMMDD: day.yyyymmdd)
            .formatted(style)
    }
}
