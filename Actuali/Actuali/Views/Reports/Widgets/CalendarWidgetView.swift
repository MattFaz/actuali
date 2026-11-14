import SwiftUI

struct CalendarWidgetView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let displayName: String
    let data: CalendarData

    /// Upstream's card lays every month out horizontally with scrolling; on
    /// iPhone we show the most recent two so cells stay readable.
    private var visibleMonths: [CalendarMonthData] {
        Array(data.months.suffix(2))
    }

    private var weekdaySymbols: [String] {
        CalendarWidgetFormatting.weekdaySymbols(
            locale: locale,
            firstDayOfWeekIdx: data.firstDayOfWeekIdx
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                ReportCardTitle(displayName)
                Spacer()
                CalendarTotalsView(
                    incomeCents: data.totalIncomeCents,
                    expenseCents: data.totalExpenseCents
                )
            }
            if data.months.isEmpty {
                Text(ReportStrings.text("No data", locale: locale))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(visibleMonths, id: \.monthStart) { month in
                        CalendarMonthGridView(month: month, weekdaySymbols: weekdaySymbols, locale: locale)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct CalendarTotalsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let incomeCents: Int
    let expenseCents: Int

    var body: some View {
        HStack(spacing: 8) {
            if incomeCents != 0 {
                Label(budgetStore.displayBalance(incomeCents, locale: locale), systemImage: "arrowtriangle.up.fill")
                    .foregroundStyle(.green)
            }
            if expenseCents != 0 {
                Label(budgetStore.displayBalance(expenseCents, locale: locale), systemImage: "arrowtriangle.down.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption2.monospacedDigit())
        .labelStyle(CalendarCompactLabelStyle())
    }
}

private struct CalendarCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// `compact` is the card's thumbnail; the detail page passes false for
/// full-width months whose days can be tapped.
struct CalendarMonthGridView: View {
    let month: CalendarMonthData
    let weekdaySymbols: [String]
    let locale: Locale
    var compact = true
    var selectedCell: Int?
    var onSelect: ((Int) -> Void)?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(CalendarWidgetFormatting.monthTitle(month.monthStart, locale: locale))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                CalendarTotalsView(
                    incomeCents: month.totalIncomeCents,
                    expenseCents: month.totalExpenseCents
                )
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<7, id: \.self) { i in
                    Text(weekdaySymbols[i])
                        .font(.system(size: compact ? 9 : 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(month.days.enumerated()), id: \.offset) { index, cell in
                    if let onSelect, let day = cell.dayOfMonth {
                        Button {
                            onSelect(index)
                        } label: {
                            CalendarDayCellView(cell: cell, compact: compact, isSelected: index == selectedCell)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(CalendarWidgetFormatting.dayTitle(
                            monthStart: month.monthStart, day: day, locale: locale
                        ))
                        .accessibilityAddTraits(index == selectedCell ? .isSelected : [])
                        .accessibilityIdentifier("reportDetail.calendar.day.\(day)")
                    } else {
                        CalendarDayCellView(cell: cell, compact: compact)
                    }
                }
            }
        }
    }
}

enum CalendarWidgetFormatting {
    private static let formatterCache = FormatterCache<DateFormatter>()

    static func weekdaySymbols(locale: Locale, firstDayOfWeekIdx: Int) -> [String] {
        let formatter = formatterCache.value("CalendarWeekday|\(locale.identifier)") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: locale.identifier)
            return formatter
        }
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        return (0..<7).map { symbols[($0 + firstDayOfWeekIdx) % 7] }
    }

    static func monthTitle(_ date: Date, locale: Locale) -> String {
        ReportMonthYearFormatting.string(from: date, locale: locale)
    }

    /// "Friday, November 13, 2026" for a day of the month starting at
    /// `monthStart`. UTC throughout, like the engine's month starts.
    static func dayTitle(monthStart: Date, day: Int, locale: Locale) -> String {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) ?? monthStart
        return date.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: locale, timeZone: utc))
    }
}

private struct CalendarDayCellView: View {
    let cell: CalendarDayCell
    var compact = true
    var isSelected = false

    var body: some View {
        ZStack {
            if let day = cell.dayOfMonth {
                Color(.tertiarySystemFill)
                // Upstream DayButton: bottom-anchored bars, income left half,
                // expense right half, height = share of the month's total.
                GeometryReader { geo in
                    HStack(alignment: .bottom, spacing: 0) {
                        Rectangle()
                            .fill(.green.opacity(0.7))
                            .frame(height: geo.size.height * cell.incomeSize / 100)
                        Rectangle()
                            .fill(.red.opacity(0.7))
                            .frame(height: geo.size.height * cell.expenseSize / 100)
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                Text("\(day)")
                    .font(.system(size: compact ? 8 : 13, weight: .medium))
            } else {
                Color.clear
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 3 : 6))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary, lineWidth: 2)
            }
        }
    }
}
