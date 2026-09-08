import SwiftUI
import Charts

struct CrossoverWidgetView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let displayName: String
    let data: CrossoverData

    private var yearsToRetireText: String {
        guard let years = data.yearsToRetire else {
            return ReportStrings.text("N/A", locale: locale)
        }
        return ReportStrings.yearsToRetire(years, locale: locale)
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
                    Text(ReportStrings.text("Years to Retire", locale: locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if data.points.count >= 2 {
                Chart {
                    ForEach(data.points, id: \.month) { point in
                        LineMark(
                            x: .value(ReportStrings.text("Month", locale: locale), point.month),
                            y: .value(ReportStrings.text("Income", locale: locale), Double(point.investmentIncomeCents) / 100.0),
                            series: .value(ReportStrings.text("Series", locale: locale), ReportStrings.text("Investment income", locale: locale))
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.green)
                        LineMark(
                            x: .value(ReportStrings.text("Month", locale: locale), point.month),
                            y: .value(ReportStrings.text("Expenses", locale: locale), Double(point.expensesCents) / 100.0),
                            series: .value(ReportStrings.text("Series", locale: locale), ReportStrings.text("Expenses", locale: locale))
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.red)
                    }
                    // Upstream draws adjusted (target) expenses as a dashed
                    // red line over the projected months only.
                    ForEach(data.points.filter { $0.adjustedExpensesCents != nil }, id: \.month) { point in
                        LineMark(
                            x: .value(ReportStrings.text("Month", locale: locale), point.month),
                            y: .value(ReportStrings.text("Target", locale: locale), Double(point.adjustedExpensesCents ?? 0) / 100.0),
                            series: .value(ReportStrings.text("Series", locale: locale), ReportStrings.text("Target income", locale: locale))
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                    }
                    if let crossoverMonth = data.crossoverMonth {
                        RuleMark(x: .value(ReportStrings.text("Crossover", locale: locale), crossoverMonth))
                            .foregroundStyle(.blue)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .frame(height: 180)
                // Keep the trend visible without exposing chart-axis amounts.
                .modifier(ReportCurrencyYAxis(
                    numberFormat: budgetStore.numberFormat,
                    currencyCode: budgetStore.currencyCode,
                    narrowSymbol: budgetStore.useNarrowCurrencySymbol,
                    locale: locale,
                    hidden: budgetStore.hideBalances))
                .accessibilityHidden(budgetStore.hideBalances)
            } else {
                Text(ReportStrings.text("Not enough data", locale: locale))
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
