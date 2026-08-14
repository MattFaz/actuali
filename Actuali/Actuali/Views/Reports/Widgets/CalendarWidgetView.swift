import SwiftUI

struct CalendarWidgetView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    let displayName: String
    let data: CalendarData

    /// Upstream's card lays every month out horizontally with scrolling; on
    /// iPhone we show the most recent two so cells stay readable.
    private var visibleMonths: [CalendarMonthData] {
        Array(data.months.suffix(2))
    }

    private var weekdaySymbols: [String] {
        let symbols = DateFormatter().veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        return (0..<7).map { symbols[($0 + data.firstDayOfWeekIdx) % 7] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(displayName).font(.headline)
                Spacer()
                CalendarTotalsView(
                    incomeCents: data.totalIncomeCents,
                    expenseCents: data.totalExpenseCents
                )
            }
            if data.months.isEmpty {
                Text("No data")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(visibleMonths, id: \.monthStart) { month in
                        CalendarMonthGridView(month: month, weekdaySymbols: weekdaySymbols)
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
    let incomeCents: Int
    let expenseCents: Int

    var body: some View {
        HStack(spacing: 8) {
            if incomeCents != 0 {
                Label(budgetStore.displayBalance(incomeCents), systemImage: "arrowtriangle.up.fill")
                    .foregroundStyle(.green)
            }
            if expenseCents != 0 {
                Label(budgetStore.displayBalance(expenseCents), systemImage: "arrowtriangle.down.fill")
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

private struct CalendarMonthGridView: View {
    let month: CalendarMonthData
    let weekdaySymbols: [String]

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        // Month starts are UTC dates; format them in UTC so the label can't
        // shift into the neighboring month in negative-offset timezones.
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.monthFormatter.string(from: month.monthStart))
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
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(month.days.enumerated()), id: \.offset) { _, cell in
                    CalendarDayCellView(cell: cell)
                }
            }
        }
    }
}

private struct CalendarDayCellView: View {
    let cell: CalendarDayCell

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
                    .font(.system(size: 8, weight: .medium))
            } else {
                Color.clear
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
