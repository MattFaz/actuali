import SwiftUI
import Charts

struct BudgetAnalysisWidgetView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let displayName: String
    let data: BudgetAnalysisData

    private struct Mark: Identifiable {
        let month: Date
        let series: String
        let amount: Double

        var id: String { "\(series)-\(month.timeIntervalSinceReferenceDate)" }
    }

    private static func monthDate(_ yyyymm: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: yyyymm / 100, month: yyyymm % 100, day: 1)) ?? Date()
    }

    // Budgeted / spent / overspending, matching upstream's graph series.
    // Spent stays negative, as upstream plots it.
    private var valueMarks: [Mark] {
        data.intervalData.flatMap { p in
            [
                Mark(month: Self.monthDate(p.month), series: ReportStrings.text("Budgeted", locale: locale), amount: Double(p.budgetedCents) / 100),
                Mark(month: Self.monthDate(p.month), series: ReportStrings.text("Spent", locale: locale), amount: Double(p.spentCents) / 100),
                Mark(month: Self.monthDate(p.month), series: ReportStrings.text("Overspending", locale: locale), amount: Double(p.overspendingAdjustmentCents) / 100)
            ]
        }
    }

    private var balanceMarks: [Mark] {
        data.intervalData.map { p in
            Mark(month: Self.monthDate(p.month), series: ReportStrings.text("Balance", locale: locale), amount: Double(p.balanceCents) / 100)
        }
    }

    private var seriesDomain: [String] {
        var domain: [String] = []
        if !data.balanceOnly {
            domain += [
                ReportStrings.text("Budgeted", locale: locale),
                ReportStrings.text("Spent", locale: locale),
                ReportStrings.text("Overspending", locale: locale)
            ]
        }
        if data.showBalance || data.balanceOnly {
            domain.append(ReportStrings.text("Balance", locale: locale))
        }
        return domain
    }

    private var seriesRange: [Color] {
        let colors: [String: Color] = [
            ReportStrings.text("Budgeted", locale: locale): .green,
            ReportStrings.text("Spent", locale: locale): .red,
            ReportStrings.text("Overspending", locale: locale): .orange,
            ReportStrings.text("Balance", locale: locale): .gray
        ]
        return seriesDomain.compactMap { colors[$0] }
    }

    // Resolve the bar/line choice into a single erased type. Using an if/else
    // directly inside the Chart builder yields _ConditionalContent, whose
    // ChartContent conformance is iOS 27+ only.
    private func valueMark(_ mark: Mark) -> AnyChartContent {
        if data.graphType == .bar {
            AnyChartContent(
                BarMark(
                    x: .value(ReportStrings.text("Month", locale: locale), mark.month, unit: .month),
                    y: .value(ReportStrings.text("Amount", locale: locale), mark.amount)
                )
                .foregroundStyle(by: .value(ReportStrings.text("Series", locale: locale), mark.series))
                .position(by: .value(ReportStrings.text("Series", locale: locale), mark.series))
            )
        } else {
            AnyChartContent(
                LineMark(
                    x: .value(ReportStrings.text("Month", locale: locale), mark.month, unit: .month),
                    y: .value(ReportStrings.text("Amount", locale: locale), mark.amount)
                )
                .foregroundStyle(by: .value(ReportStrings.text("Series", locale: locale), mark.series))
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(displayName).font(.headline)
                Spacer()
                // Upstream's card headline: the latest interval's balance,
                // green when non-negative, red otherwise.
                if let last = data.intervalData.last {
                    Text(budgetStore.displayBalanceWholeUnits(last.balanceCents, locale: locale))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(last.balanceCents >= 0 ? Color.green : Color.red)
                }
            }

            if data.intervalData.isEmpty {
                Text(ReportStrings.text("No data", locale: locale))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                Chart {
                    if !data.balanceOnly {
                        ForEach(valueMarks) { mark in
                            valueMark(mark)
                        }
                    }
                    if data.showBalance || data.balanceOnly {
                        ForEach(balanceMarks) { mark in
                            LineMark(
                                x: .value(ReportStrings.text("Month", locale: locale), mark.month, unit: .month),
                                y: .value(ReportStrings.text("Amount", locale: locale), mark.amount)
                            )
                            .foregroundStyle(by: .value(ReportStrings.text("Series", locale: locale), mark.series))
                        }
                    }
                }
                .chartForegroundStyleScale(domain: seriesDomain, range: seriesRange)
                .frame(height: 200)
                // Keep the trend visible without exposing chart-axis amounts.
                .modifier(ReportCurrencyYAxis(
                    numberFormat: budgetStore.numberFormat,
                    currencyCode: budgetStore.currencyCode,
                    narrowSymbol: budgetStore.useNarrowCurrencySymbol,
                    locale: locale,
                    hidden: budgetStore.hideBalances))
                .accessibilityHidden(budgetStore.hideBalances)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
