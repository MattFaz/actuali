import Charts
import SwiftUI

extension CustomReportData {
    /// The interval-by-series table behind the chart kinds that get a detail
    /// page. Bar and area reports become one series; donut and table cards
    /// already list everything, so they have none.
    var detailTable: Stacked? {
        let table: Stacked
        switch kind {
        case .stacked(let stacked), .lines(let stacked, _):
            table = stacked
        case .bars(let bars, _), .area(let bars):
            table = Stacked(intervalLabels: bars.map(\.label), seriesNames: [name], values: [bars.map(\.valueUnits)])
        case .donut, .table, .unsupported:
            return nil
        }
        return table.intervalLabels.isEmpty || table.seriesNames.isEmpty ? nil : table
    }
}

extension CustomReportData.Stacked {
    /// Per-interval sum of the series not in `hidden`.
    func totals(hiding hidden: Set<Int>) -> [Double] {
        intervalLabels.indices.map { interval in
            values.indices.filter { !hidden.contains($0) }.reduce(0) { $0 + values[$1][interval] }
        }
    }
}

/// Full-screen version of a custom report card: scrub the chart to read one
/// interval, and switch series off to see the rest without them.
struct CustomReportDetailView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let data: CustomReportData
    let table: CustomReportData.Stacked

    @State private var selected: String?
    @State private var hidden: Set<Int> = []

    /// The interval the readout and the lists describe: the one under the
    /// finger, otherwise the latest.
    private var shownInterval: Int {
        selected.flatMap(table.intervalLabels.firstIndex(of:)) ?? table.intervalLabels.count - 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                readout
                chart
                if table.seriesNames.count > 1 {
                    seriesList
                } else {
                    intervalList
                }
            }
            .padding()
        }
        .navigationTitle(data.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(table.intervalLabels[shownInterval])
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(amount(table.totals(hiding: hidden)[shownInterval]))
                .font(.system(size: 34, weight: .bold))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            if !data.rangeLabel.isEmpty {
                Text(data.rangeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reportDetail.readout")
    }

    private var chart: some View {
        Chart {
            ForEach(points) { mark($0) }
            // Area reports draw a line along the top of the fill, as the card does.
            ForEach(isArea ? points : []) { point in
                LineMark(x: x(point), y: y(point))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(point.color)
            }
            ForEach(selected.map { [$0] } ?? [], id: \.self) { interval in
                RuleMark(x: .value(ReportStrings.text("Interval", locale: locale), interval))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: $selected)
        .chartPlotStyle { $0.frame(height: 240) }
        .modifier(ReportIntervalXAxis(labels: table.intervalLabels))
        .modifier(ReportCurrencyYAxis(
            numberFormat: budgetStore.numberFormat,
            currencyCode: budgetStore.currencyCode,
            narrowSymbol: budgetStore.useNarrowCurrencySymbol,
            locale: locale,
            hidden: budgetStore.hideBalances
        ))
        // The readout and the lists below carry the same numbers as text.
        .accessibilityHidden(true)
    }

    private var seriesList: some View {
        VStack(spacing: 0) {
            ForEach(table.seriesNames.indices, id: \.self) { series in
                let isHidden = hidden.contains(series)
                if series > 0 {
                    Divider()
                }
                Button {
                    hidden.formSymmetricDifference([series])
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .strokeBorder(color(series), lineWidth: 2)
                            .background(Circle().fill(isHidden ? .clear : color(series)))
                            .frame(width: 10, height: 10)
                        Text(table.seriesNames[series])
                            .lineLimit(1)
                        Spacer()
                        Text(isHidden
                            ? ReportStrings.text("Hidden", locale: locale)
                            : amount(table.values[series][shownInterval]))
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    .foregroundStyle(isHidden ? .secondary : .primary)
                    .padding(.horizontal)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reportDetail.series.\(series)")
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var intervalList: some View {
        LazyVStack(spacing: 0) {
            ForEach(table.intervalLabels.indices, id: \.self) { interval in
                if interval > 0 {
                    Divider()
                }
                HStack {
                    Text(table.intervalLabels[interval])
                    Spacer()
                    Text(amount(table.values[0][interval]))
                        .monospacedDigit()
                }
                .font(.subheadline)
                .fontWeight(interval == shownInterval ? .semibold : .regular)
                .padding(.horizontal)
                .frame(minHeight: 44)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Marks

    private struct Point: Identifiable {
        let series: Int
        let interval: String
        let value: Double
        let color: Color
        let id: String
    }

    private var isArea: Bool {
        if case .area = data.kind {
            return true
        }
        return false
    }

    /// One point per visible series and interval. Colours are set per point
    /// rather than through a style scale, so hiding a series doesn't shift
    /// the colours of the others.
    private var points: [Point] {
        table.seriesNames.indices.filter { !hidden.contains($0) }.flatMap { series in
            table.intervalLabels.indices.map { interval in
                let value = table.values[series][interval]
                return Point(series: series, interval: table.intervalLabels[interval], value: value,
                             color: color(series, value: value), id: "\(series)|\(interval)")
            }
        }
    }

    private func color(_ series: Int, value: Double = 0) -> Color {
        switch data.kind {
        case .bars(_, signed: true): value < 0 ? .red : .green
        case .bars, .area: .accentColor
        default: CustomReportWidgetView.palette[series % CustomReportWidgetView.palette.count]
        }
    }

    private func x(_ point: Point) -> PlottableValue<String> {
        .value(ReportStrings.text("Interval", locale: locale), point.interval)
    }

    private func y(_ point: Point) -> PlottableValue<Double> {
        .value(ReportStrings.text("Amount", locale: locale), point.value)
    }

    /// AnyChartContent because a switch directly inside the Chart builder
    /// yields _ConditionalContent, whose ChartContent conformance is iOS 27+.
    private func mark(_ point: Point) -> AnyChartContent {
        switch data.kind {
        case .lines:
            AnyChartContent(
                LineMark(x: x(point), y: y(point),
                         series: .value(ReportStrings.text("Series", locale: locale), String(point.series)))
                    .foregroundStyle(point.color)
            )
        case .area:
            AnyChartContent(
                AreaMark(x: x(point), y: y(point))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(point.color.opacity(0.3))
            )
        default:
            AnyChartContent(BarMark(x: x(point), y: y(point)).foregroundStyle(point.color))
        }
    }

    private func amount(_ units: Double) -> String {
        budgetStore.displayBalance(Int((units * 100).rounded()), locale: locale)
    }
}
