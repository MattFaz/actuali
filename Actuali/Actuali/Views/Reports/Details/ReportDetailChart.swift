import Charts
import SwiftUI

/// The chart of a `ReportChartDetail`, drawn two ways: full size with axes
/// and scrubbing on the detail page, and as a small axis-less sketch on the
/// card when there is no `selection` to drive.
struct ReportDetailChart: View {
    @Environment(\.locale) private var locale
    let detail: ReportChartDetail
    var hidden: Set<Int> = []
    /// nil on a card: nothing to scrub.
    var selection: Binding<String?>?

    @State private var plotWidth: CGFloat = 0

    private var isLine: Bool {
        detail.style == .lines || detail.style == .area
    }

    /// A string axis gives each interval a band and centres its mark there,
    /// which leaves half a band empty at both ends of a line. This is how far
    /// to stretch the scale past the plot so the line spans it, stopping
    /// `inset` short so the selection dot at either end still fits.
    nonisolated static func overhang(plotWidth: CGFloat, intervals: Int, inset: CGFloat = 6) -> CGFloat {
        guard intervals > 1 else { return 0 }
        return max(0, (plotWidth - 2 * CGFloat(intervals) * inset) / (2 * CGFloat(intervals - 1)))
    }

    private var selected: String? {
        selection?.wrappedValue
    }

    var body: some View {
        let chart = Chart {
            ForEach(bandPoints) { point in
                AreaMark(x: x(point), yStart: y(point), yEnd: .value(ReportStrings.text("Amount", locale: locale), point.upper))
                    .foregroundStyle(point.color.opacity(0.18))
            }
            ForEach(points) { mark($0) }
            // Area charts draw a line along the top of the fill.
            ForEach(detail.style == .area ? points : []) { point in
                LineMark(x: x(point), y: y(point))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(point.color)
                    .lineStyle(Self.line())
            }
            // Upstream draws each series' trend dashed, in the series colour.
            ForEach(trendPoints) { point in
                LineMark(x: x(point), y: y(point),
                         series: .value(ReportStrings.text("Series", locale: locale), "trend|" + String(point.series)))
                    .foregroundStyle(point.color)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            ForEach(selected.map { [$0] } ?? [], id: \.self) { interval in
                RuleMark(x: .value(ReportStrings.text("Interval", locale: locale), interval))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            // Lines mark the selected interval with a dot on each series;
            // bars dim the others instead (see `mark`).
            ForEach(selectedLinePoints) { point in
                PointMark(x: x(point), y: y(point))
                    .symbol {
                        Circle()
                            .fill(point.color)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    }
            }
        }
        .chartLegend(.hidden)
        .chartXScale(range: .plotDimension(
            padding: isLine ? -Self.overhang(plotWidth: plotWidth, intervals: detail.intervals.count) : 0
        ))
        .chartBackground { proxy in
            Color.clear.onChange(of: proxy.plotSize.width, initial: true) { _, width in
                plotWidth = width
            }
        }

        if let selection {
            chart
                .chartXSelection(value: selection)
                .chartPlotStyle { $0.frame(height: 240) }
                .modifier(ReportIntervalXAxis(labels: detail.intervals, gridLines: false, reachesEdges: isLine))
                .modifier(YAxis(unit: detail.unit))
        } else {
            chart
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                // A sketch shows the shape: bars still grow from zero, but a
                // line fills the height instead of hugging the top.
                .chartYScale(domain: .automatic(includesZero: detail.style == .stackedBars || detail.style == .groupedBars))
                .frame(height: 64)
        }
    }

    // MARK: - Marks

    private struct Point: Identifiable {
        let series: Int
        let interval: String
        let value: Double
        let color: Color
        let dashed: Bool
        /// Band points only: the top of the range (`value` is the bottom).
        var upper = 0.0
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

    private var bandPoints: [Point] {
        guard let band = detail.band else { return [] }
        return detail.intervals.indices.map {
            Point(series: -1, interval: detail.intervals[$0], value: band.lower[$0], color: band.color, dashed: false, upper: band.upper[$0])
        }
    }

    private var selectedLinePoints: [Point] {
        guard detail.style == .lines || detail.style == .area, let selected else { return [] }
        // A line that turns dashed has its turning point twice; one dot is enough.
        var seen = Set<Int>()
        return points.filter { $0.interval == selected && seen.insert($0.series).inserted }
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

    private static func line(dashed: Bool = false) -> StrokeStyle {
        StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: dashed ? [5, 5] : [])
    }

    /// While scrubbing, the bars of every other interval step back.
    private func barOpacity(_ point: Point) -> Double {
        selected == nil || selected == point.interval ? 1 : 0.35
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
                    .lineStyle(Self.line(dashed: point.dashed))
            )
        case .area:
            return AnyChartContent(
                AreaMark(x: x(point), y: y(point))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(point.color.opacity(0.16))
            )
        case .groupedBars:
            return AnyChartContent(
                BarMark(x: x(point), y: y(point))
                    .foregroundStyle(point.color)
                    .cornerRadius(3)
                    .opacity(barOpacity(point))
                    .position(by: seriesKey)
            )
        case .stackedBars:
            return AnyChartContent(
                BarMark(x: x(point), y: y(point))
                    .foregroundStyle(point.color)
                    // Only a bar standing alone gets rounded ends; a stack would show gaps.
                    .cornerRadius(detail.series.count == 1 ? 3 : 0)
                    .opacity(barOpacity(point))
            )
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

extension ReportChartDetail {
    /// An amount in this chart's unit, masked when balances are hidden.
    @MainActor
    func text(for value: Double, compact: Bool = false, store: BudgetStore, locale: Locale) -> String {
        switch unit {
        case .days:
            return ReportStrings.localized("\(Int(value.rounded())) days", locale: locale)
        case .currency where (compact || self.compact) && abs(value) >= 1000:
            guard !store.hideBalances else { return BudgetStore.hiddenBalanceText }
            return CurrencyAmountFormat.compactString(
                units: value, currencyCode: store.currencyCode, narrowSymbol: store.useNarrowCurrencySymbol,
                numberFormat: store.numberFormat, locale: locale
            )
        case .currency:
            return store.displayBalance(Int((value * 100).rounded()), locale: locale)
        }
    }

    /// The series a card has room to name: the largest by magnitude in the
    /// latest interval, in legend order.
    func leadingSeries(limit: Int = 3) -> [Int] {
        guard let latest = intervals.indices.last else { return [] }
        return series.indices
            .sorted { abs(series[$0].values[latest]) > abs(series[$1].values[latest]) }
            .prefix(limit)
            .sorted()
    }
}
