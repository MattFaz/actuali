import Charts
import SwiftUI

/// Full-screen version of a chart card: scrub the chart to read one interval
/// and, where the series add up, switch series off to see the rest without
/// them.
struct ReportChartDetailView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let detail: ReportChartDetail

    @State private var selected: String?
    @State private var hidden: Set<Int> = []

    /// The interval the readout and the lists describe: the one under the
    /// finger, otherwise the latest.
    private var shownInterval: Int {
        selected.flatMap(detail.intervals.firstIndex(of:)) ?? detail.intervals.count - 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                readout
                chart
                if detail.series.count > 1 {
                    seriesList
                } else {
                    intervalList
                }
            }
            .padding()
        }
        .navigationTitle(detail.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let value = detail.readoutValue(at: shownInterval, hiding: hidden) {
                Text(detail.intervals[shownInterval])
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(amount(value))
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            } else {
                Text(detail.intervals[shownInterval])
                    .font(.title2.weight(.bold))
            }
            if !detail.caption.isEmpty {
                Text(detail.caption)
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
            // Area charts draw a line along the top of the fill, as the cards do.
            ForEach(detail.style == .area ? points : []) { point in
                LineMark(x: x(point), y: y(point))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(point.color)
            }
            // Upstream draws each series' trend dashed, in the series colour.
            ForEach(trendPoints) { point in
                LineMark(x: x(point), y: y(point),
                         series: .value(ReportStrings.text("Series", locale: locale), "trend|\(point.series)"))
                    .foregroundStyle(point.color)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
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
        .modifier(ReportIntervalXAxis(labels: detail.intervals))
        .modifier(YAxis(unit: detail.unit))
        // The readout and the lists below carry the same numbers as text.
        .accessibilityHidden(true)
    }

    private var seriesList: some View {
        VStack(spacing: 0) {
            ForEach(detail.series.indices, id: \.self) { index in
                if index > 0 {
                    Divider()
                }
                if detail.canHideSeries {
                    Button {
                        hidden.formSymmetricDifference([index])
                    } label: {
                        seriesRow(index, isHidden: hidden.contains(index))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("reportDetail.series.\(index)")
                } else {
                    seriesRow(index, isHidden: false)
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func seriesRow(_ index: Int, isHidden: Bool) -> some View {
        let series = detail.series[index]
        return HStack(spacing: 10) {
            Circle()
                .strokeBorder(series.color, lineWidth: 2)
                .background(Circle().fill(isHidden ? .clear : series.color))
                .frame(width: 10, height: 10)
            Text(series.name)
                .lineLimit(1)
            Spacer()
            Text(isHidden ? ReportStrings.text("Hidden", locale: locale) : amount(series.values[shownInterval]))
                .monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(isHidden ? .secondary : .primary)
        .padding(.horizontal)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var intervalList: some View {
        LazyVStack(spacing: 0) {
            ForEach(detail.intervals.indices, id: \.self) { interval in
                if interval > 0 {
                    Divider()
                }
                HStack {
                    Text(detail.intervals[interval])
                    Spacer()
                    Text(amount(detail.series[0].values[interval]))
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
        let dashed: Bool
        var id: String {
            "\(series)|\(interval)|\(dashed)"
        }
    }

    /// One point per visible series and interval. Colours are set per point
    /// rather than through a style scale, so hiding a series doesn't shift
    /// the colours of the others. A line that turns dashed is two segments
    /// sharing the point where it turns.
    private var points: [Point] {
        detail.series.indices.filter { !hidden.contains($0) }.flatMap { index -> [Point] in
            let series = detail.series[index]
            let turn = detail.style == .lines ? series.dashedFrom ?? series.values.count : series.values.count
            func point(_ interval: Int, dashed: Bool) -> Point {
                let value = series.values[interval]
                let color: Color = detail.signed ? (value < 0 ? .red : .green) : series.color
                return Point(series: index, interval: detail.intervals[interval], value: value, color: color, dashed: dashed)
            }
            return series.values.indices.filter { $0 < turn }.map { point($0, dashed: false) }
                + series.values.indices.filter { $0 >= max(turn - 1, 0) && turn < series.values.count }.map { point($0, dashed: true) }
        }
    }

    private var trendPoints: [Point] {
        guard detail.style == .lines, let first = detail.intervals.first, let last = detail.intervals.last else { return [] }
        return detail.series.indices.filter { !hidden.contains($0) }.flatMap { index -> [Point] in
            guard let trend = detail.series[index].trend else { return [] }
            let color = detail.series[index].color
            return [Point(series: index, interval: first, value: trend.startUnits, color: color, dashed: true),
                    Point(series: index, interval: last, value: trend.endUnits, color: color, dashed: true)]
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
        let seriesKey = PlottableValue.value(ReportStrings.text("Series", locale: locale), "\(point.series)|\(point.dashed)")
        switch detail.style {
        case .lines:
            return AnyChartContent(
                LineMark(x: x(point), y: y(point), series: seriesKey)
                    .foregroundStyle(point.color)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: point.dashed ? [5, 5] : []))
            )
        case .area:
            return AnyChartContent(
                AreaMark(x: x(point), y: y(point))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(point.color.opacity(0.3))
            )
        case .groupedBars:
            return AnyChartContent(BarMark(x: x(point), y: y(point)).foregroundStyle(point.color).position(by: seriesKey))
        case .stackedBars:
            return AnyChartContent(BarMark(x: x(point), y: y(point)).foregroundStyle(point.color))
        }
    }

    private func amount(_ value: Double) -> String {
        switch detail.unit {
        case .currency: budgetStore.displayBalance(Int((value * 100).rounded()), locale: locale)
        case .days: ReportStrings.localized("\(Int(value.rounded())) days", locale: locale)
        }
    }

    private struct YAxis: ViewModifier {
        @EnvironmentObject private var budgetStore: BudgetStore
        @Environment(\.locale) private var locale
        let unit: ReportChartDetail.Unit

        func body(content: Content) -> some View {
            if unit == .currency {
                content.modifier(ReportCurrencyYAxis(
                    numberFormat: budgetStore.numberFormat,
                    currencyCode: budgetStore.currencyCode,
                    narrowSymbol: budgetStore.useNarrowCurrencySymbol,
                    locale: locale,
                    hidden: budgetStore.hideBalances
                ))
            } else {
                content
            }
        }
    }
}
