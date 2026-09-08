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
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }
}