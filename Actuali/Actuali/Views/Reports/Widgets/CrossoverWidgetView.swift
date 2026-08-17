import SwiftUI
import Charts

struct CrossoverWidgetView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    let displayName: String
    let data: CrossoverData

    private var yearsToRetireText: String {
        guard let years = data.yearsToRetire else { return String(localized: "N/A") }
        return String(format: String(localized: "%@ years"), years.formatted(.number.precision(.fractionLength(0...2))))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(displayName).font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(yearsToRetireText)
                        .font(.subheadline)
                        .monospacedDigit()
                    Text(String(localized: "Years to Retire"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if data.points.count >= 2 {
                Chart {
                    ForEach(data.points, id: \.month) { point in
                        LineMark(
                            x: .value("Month", point.month),
                            y: .value("Income", Double(point.investmentIncomeCents) / 100.0),
                            series: .value("Series", "Investment income")
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.green)
                        LineMark(
                            x: .value("Month", point.month),
                            y: .value("Expenses", Double(point.expensesCents) / 100.0),
                            series: .value("Series", "Expenses")
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.red)
                    }
                    // Upstream draws adjusted (target) expenses as a dashed
                    // red line over the projected months only.
                    ForEach(data.points.filter { $0.adjustedExpensesCents != nil }, id: \.month) { point in
                        LineMark(
                            x: .value("Month", point.month),
                            y: .value("Target", Double(point.adjustedExpensesCents ?? 0) / 100.0),
                            series: .value("Series", "Target income")
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                    }
                    if let crossoverMonth = data.crossoverMonth {
                        RuleMark(x: .value("Crossover", crossoverMonth))
                            .foregroundStyle(.blue)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .frame(height: 180)
                // Keep the trend visible without exposing chart-axis amounts.
                .chartYAxis(budgetStore.hideBalances ? .hidden : .automatic)
                .accessibilityHidden(budgetStore.hideBalances)
            } else {
                Text(String(localized: "Not enough data"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
