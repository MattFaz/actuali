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
}
