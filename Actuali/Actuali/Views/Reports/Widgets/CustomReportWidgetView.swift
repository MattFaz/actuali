import SwiftUI
import Charts

struct CustomReportWidgetView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    let data: CustomReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(data.name).font(.headline)
                if !data.rangeLabel.isEmpty {
                    Text(data.rangeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var content: some View {
        switch data.kind {
        case .bars(let bars, let signed):
            if bars.isEmpty {
                emptyText
            } else {
                Chart(Array(bars.enumerated()), id: \.offset) { _, bar in
                    BarMark(
                        x: .value("Label", bar.label),
                        y: .value("Amount", bar.valueUnits)
                    )
                    .foregroundStyle(signed
                        ? (bar.valueUnits < 0 ? Color.red : Color.green)
                        : Color.accentColor)
                }
                .frame(height: 180)
                // Financial chart axes otherwise reveal the underlying totals.
                .chartYAxis(budgetStore.hideBalances ? .hidden : .automatic)
                .accessibilityHidden(budgetStore.hideBalances)
            }

        case .stacked(let stacked):
            if stacked.seriesNames.isEmpty {
                emptyText
            } else {
                // Flatten to (interval, series, value) points for Charts.
                let points = stacked.seriesNames.enumerated().flatMap { s, name in
                    stacked.intervalLabels.enumerated().map { i, label in
                        StackPoint(interval: label, series: name,
                                   value: stacked.values[s][i])
                    }
                }
                Chart(points) { point in
                    BarMark(
                        x: .value("Interval", point.interval),
                        y: .value("Amount", point.value)
                    )
                    .foregroundStyle(by: .value("Group", point.series))
                }
                .chartLegend(.visible)
                .frame(height: 200)
                // Financial chart axes otherwise reveal the underlying totals.
                .chartYAxis(budgetStore.hideBalances ? .hidden : .automatic)
                .accessibilityHidden(budgetStore.hideBalances)
            }

        case .table(let rows):
            if rows.isEmpty {
                emptyText
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.name).font(.subheadline)
                            Spacer()
                            Text(budgetStore.displayBalance(Int((row.totalUnits * 100).rounded())))
                                .font(.subheadline)
                                .monospacedDigit()
                        }
                    }
                }
            }

        case .unsupported(let reason):
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
        }
    }

    private var emptyText: some View {
        Text("No data in range")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
    }

    private struct StackPoint: Identifiable {
        let interval: String
        let series: String
        let value: Double
        var id: String { interval + "|" + series }
    }
}
