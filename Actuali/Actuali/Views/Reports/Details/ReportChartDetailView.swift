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

    /// A list under the chart, where the numbers can't sit beside the headline.
    private enum Breakdown { case series, intervals, none }

    private var breakdown: Breakdown {
        if detail.series.count > 1 {
            return detail.showsInlineLegend ? .none : .series
        }
        // One series with figures for the range or a band needs no table.
        return detail.stats.isEmpty && detail.band == nil ? .intervals : .none
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                readout
                chart
                Text(ReportStrings.text("Drag across the chart to inspect a point.", locale: locale))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                switch breakdown {
                case .series: seriesList
                case .intervals: intervalList
                case .none: EmptyView()
                }
                if !detail.stats.isEmpty {
                    statsList
                }
            }
            .padding()
        }
        .navigationTitle(detail.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
    }

    // MARK: - Readout

    private struct LegendItem: Identifiable {
        let id: Int
        let name: String
        let value: Double
        let color: Color
    }

    /// The other numbers at the shown interval that belong beside the
    /// headline: a short series list, and the ends of a band.
    private var inlineLegend: [LegendItem] {
        var items: [LegendItem] = []
        if detail.showsInlineLegend {
            items += detail.series.indices.map {
                LegendItem(id: $0, name: detail.series[$0].name, value: detail.series[$0].values[shownInterval],
                           color: detail.series[$0].color)
            }
        }
        if let band = detail.band {
            items.append(LegendItem(id: -1, name: band.lowerName, value: band.lower[shownInterval], color: .secondary))
            items.append(LegendItem(id: -2, name: band.upperName, value: band.upper[shownInterval], color: band.color))
        }
        return items
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !detail.caption.isEmpty {
                Text(detail.caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            if let value = detail.readoutValue(at: shownInterval, hiding: hidden) {
                Text(detail.intervals[shownInterval])
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(amount(value))
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    // A difference is good or bad by its sign.
                    .foregroundStyle(detail.readout == .difference && !budgetStore.hideBalances
                        ? (value < 0 ? Color.red : Color.green) : Color.primary)
                if !detail.readoutLabel.isEmpty {
                    Text(detail.readoutLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(detail.intervals[shownInterval])
                    .font(.title2.weight(.bold))
            }
            if !inlineLegend.isEmpty {
                // Side by side when they fit, stacked when they don't.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { legendItems }
                    VStack(alignment: .leading, spacing: 4) { legendItems }
                }
                .padding(.top, 6)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reportDetail.readout")
    }

    private var legendItems: some View {
        ForEach(inlineLegend) { item in
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(item.color)
                    .frame(width: 10, height: 10)
                Text(item.name)
                    .foregroundStyle(.secondary)
                Text(amount(item.value))
                    .monospacedDigit()
            }
            .font(.subheadline)
            .lineLimit(1)
        }
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            ForEach(bandPoints) { point in
                AreaMark(x: x(point), yStart: y(point), yEnd: .value(ReportStrings.text("Amount", locale: locale), point.upper))
                    .foregroundStyle(point.color.opacity(0.18))
            }
            ForEach(points) { mark($0) }
            // Area charts draw a line along the top of the fill, as the cards do.
            ForEach(detail.style == .area ? points : []) { point in
                LineMark(x: x(point), y: y(point))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(point.color)
                    .lineStyle(Self.line())
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
        .chartXSelection(value: $selected)
        .chartPlotStyle { $0.frame(height: 240) }
        .modifier(ReportIntervalXAxis(labels: detail.intervals, gridLines: false))
        .modifier(YAxis(unit: detail.unit))
        // Where a list below carries the same numbers as text, the chart
        // would only repeat them. Otherwise it is the only way to them, so
        // it stays reachable unless amounts are hidden.
        .accessibilityHidden(breakdown != .none || budgetStore.hideBalances)
    }

    // MARK: - Lists

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
                row(detail.intervals[interval], amount(detail.series[0].values[interval]))
                    .fontWeight(interval == shownInterval ? .semibold : .regular)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var statsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(detail.stats.enumerated()), id: \.offset) { index, stat in
                if index > 0 {
                    Divider()
                }
                switch stat.value {
                case .amount(let value): row(stat.label, amount(value)).accessibilityElement(children: .combine)
                case .text(let text): row(stat.label, text).accessibilityElement(children: .combine)
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("reportDetail.stats")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .monospacedDigit()
                .fontWeight(.semibold)
        }
        .font(.subheadline)
        .padding(.horizontal)
        .frame(minHeight: 44)
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

    private func amount(_ value: Double) -> String {
        switch detail.unit {
        case .days:
            return ReportStrings.localized("\(Int(value.rounded())) days", locale: locale)
        case .currency where detail.compact && abs(value) >= 1000:
            guard !budgetStore.hideBalances else { return BudgetStore.hiddenBalanceText }
            return CurrencyAmountFormat.compactString(
                units: value, currencyCode: budgetStore.currencyCode, narrowSymbol: budgetStore.useNarrowCurrencySymbol,
                numberFormat: budgetStore.numberFormat, locale: locale
            )
        case .currency:
            return budgetStore.displayBalance(Int((value * 100).rounded()), locale: locale)
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
