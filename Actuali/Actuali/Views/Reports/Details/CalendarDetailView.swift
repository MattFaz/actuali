import SwiftUI

extension CalendarData {
    struct DayRef: Hashable {
        let month: Int // index into `months`
        let cell: Int // index into that month's `days`
    }

    /// The most recent day with any income or spending, where the detail
    /// page's readout starts.
    var latestActiveDay: DayRef? {
        for month in months.indices.reversed() {
            if let cell = months[month].days.lastIndex(where: {
                $0.dayOfMonth != nil && ($0.incomeCents != 0 || $0.expenseCents != 0)
            }) {
                return DayRef(month: month, cell: cell)
            }
        }
        return nil
    }
}

/// Every month in the report's range at full width, newest first. Tapping a
/// day shows its totals; the card only has room for two thumbnail months.
struct CalendarDetailView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let displayName: String
    let data: CalendarData

    @State private var selected: CalendarData.DayRef?

    private var shown: CalendarData.DayRef? {
        selected ?? data.latestActiveDay
    }

    private var weekdaySymbols: [String] {
        CalendarWidgetFormatting.weekdaySymbols(locale: locale, firstDayOfWeekIdx: data.firstDayOfWeekIdx)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ReportRangePicker()
                if let shown {
                    readout(shown)
                }
                ForEach(data.months.indices.reversed(), id: \.self) { month in
                    CalendarMonthGridView(
                        month: data.months[month],
                        weekdaySymbols: weekdaySymbols,
                        locale: locale,
                        compact: false,
                        selectedCell: shown?.month == month ? shown?.cell : nil,
                        onSelect: { selected = CalendarData.DayRef(month: month, cell: $0) }
                    )
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
    }

    private func readout(_ day: CalendarData.DayRef) -> some View {
        let month = data.months[day.month]
        let cell = month.days[day.cell]
        return VStack(alignment: .leading, spacing: 6) {
            Text(CalendarWidgetFormatting.dayTitle(monthStart: month.monthStart, day: cell.dayOfMonth ?? 1, locale: locale))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                amount("Income", cents: cell.incomeCents, color: .green)
                amount("Expenses", cents: cell.expenseCents, color: .red)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reportDetail.readout")
    }

    private func amount(_ key: String, cents: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ReportStrings.text(key, locale: locale))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(budgetStore.displayBalance(cents, locale: locale))
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(cents == 0 ? Color.primary : color)
        }
    }
}
