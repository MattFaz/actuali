import Foundation

enum WidgetDateFormatting {
    static func relative(
        _ date: Date,
        relativeTo referenceDate: Date = .now,
        locale: Locale
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        // An update can't be in the future, and numeric style reads anything
        // within a second (the gallery's `.sample` entries) as "in 0 seconds".
        // Named style only for that case, so "2 days ago" stays numeric
        // rather than becoming "avant-hier".
        let interval = min(date.timeIntervalSince(referenceDate), 0)
        formatter.dateTimeStyle = interval > -1 ? .named : .numeric
        return formatter.localizedString(fromTimeInterval: interval)
    }

    /// "Nov 5" for a YYYYMMDD integer, the budget file's date format; nil
    /// when the parts don't make a date. The same "MMM d" skeleton and
    /// locale calendar a DateFormatter template uses, as a FormatStyle so a
    /// list doesn't build a DateFormatter per row.
    static func shortDate(_ yyyymmdd: Int, locale: Locale) -> String? {
        let parts = DateComponents(year: yyyymmdd / 10000, month: yyyymmdd / 100 % 100, day: yyyymmdd % 100)
        guard let date = Calendar.current.date(from: parts) else { return nil }
        return date.formatted(Date.FormatStyle(locale: locale, calendar: locale.calendar).month(.abbreviated).day())
    }
}
