import SwiftUI
import Charts

struct BalanceForecastWidgetView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let displayName: String
    let data: BalanceForecastData

    private var historyPoints: [BalanceForecastPoint] {
        data.points.filter { !$0.isForecast }
    }

    /// Forecast segment, prefixed with the last historical point so the
    /// dashed line connects to the solid one.
    private var forecastPoints: [BalanceForecastPoint] {
        let forecast = data.points.filter(\.isForecast)
        guard let boundary = historyPoints.last, !forecast.isEmpty else { return forecast }
        return [boundary] + forecast
    }

    private var hasNegativeBalance: Bool {
        data.points.contains { $0.balanceCents < 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(displayName).font(.headline)
                Spacer()
                if let ending = data.points.last {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ReportStrings.format(
                            "Ending: %@",
                            budgetStore.displayBalanceWholeUnits(ending.balanceCents, locale: locale),
                            locale: locale
                        ))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(ending.balanceCents < 0 ? Color.red : .secondary)
                        if let lowest = data.points.min(by: { $0.balanceCents < $1.balanceCents }),
                           lowest.date != ending.date {
                            Text(ReportStrings.format(
                                "Low: %@",
                                budgetStore.displayBalanceWholeUnits(lowest.balanceCents, locale: locale),
                                locale: locale
                            ))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if data.points.count >= 2 {
                Chart {
                    ForEach(historyPoints, id: \.date) { point in
                        LineMark(
                            x: .value(ReportStrings.text("Date", locale: locale), point.date),
                            y: .value(ReportStrings.text("Balance", locale: locale), Double(point.balanceCents) / 100.0),
                            series: .value(ReportStrings.text("Segment", locale: locale), ReportStrings.text("History", locale: locale))
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.blue)
                    }
                    ForEach(forecastPoints, id: \.date) { point in
                        LineMark(
                            x: .value(ReportStrings.text("Date", locale: locale), point.date),
                            y: .value(ReportStrings.text("Balance", locale: locale), Double(point.balanceCents) / 100.0),
                            series: .value(ReportStrings.text("Segment", locale: locale), ReportStrings.text("Forecast", locale: locale))
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.blue.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    }
                    if hasNegativeBalance {
                        RuleMark(y: .value(ReportStrings.text("Zero", locale: locale), 0))
                            .foregroundStyle(.secondary.opacity(0.5))
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
