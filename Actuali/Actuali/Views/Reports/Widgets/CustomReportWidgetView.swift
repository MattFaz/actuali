import SwiftUI
import Charts

struct CustomReportChartAccessibilityRow: Equatable {
    let series: String?
    let label: String
    let value: String
}

enum CustomReportChartAccessibility {
    static func rows(
        for kind: CustomReportData.Kind,
        numberFormat: ActualNumberFormat,
        currencyCode: String,
        narrowSymbol: Bool,
        locale: Locale
    ) -> [CustomReportChartAccessibilityRow] {
        switch kind {
        case .bars(let bars, _):
            return bars.map { row(series: nil, label: $0.label, units: $0.valueUnits,
                                  numberFormat: numberFormat, currencyCode: currencyCode,
                                  narrowSymbol: narrowSymbol, locale: locale) }
        case .stacked(let stacked), .lines(let stacked, _):
            return stacked.seriesNames.enumerated().flatMap { seriesIndex, series in
                stacked.intervalLabels.indices.map { intervalIndex in
                    row(series: series, label: stacked.intervalLabels[intervalIndex],
                        units: stacked.values[seriesIndex][intervalIndex],
                        numberFormat: numberFormat, currencyCode: currencyCode,
                        narrowSymbol: narrowSymbol, locale: locale)
                }
            }
        case .area(let bars):
            return bars.map { row(series: nil, label: $0.label, units: $0.valueUnits,
                                  numberFormat: numberFormat, currencyCode: currencyCode,
                                  narrowSymbol: narrowSymbol, locale: locale) }
        case .donut(let slices, let groups):
            if groups.isEmpty {
                return slices.map { row(series: nil, label: $0.label, units: $0.valueUnits,
                                       numberFormat: numberFormat, currencyCode: currencyCode,
                                       narrowSymbol: narrowSymbol, locale: locale) }
            }
            let groupRows = groups.map { row(series: nil, label: $0.label, units: $0.valueUnits,
                                             numberFormat: numberFormat, currencyCode: currencyCode,
                                             narrowSymbol: narrowSymbol, locale: locale) }
            let sliceRows = slices.map { slice in
                row(series: slice.group.flatMap { $0 < groups.count ? groups[$0].label : nil },
                    label: slice.label, units: slice.valueUnits,
                    numberFormat: numberFormat, currencyCode: currencyCode,
                    narrowSymbol: narrowSymbol, locale: locale)
            }
            return groupRows + sliceRows
        case .table, .unsupported:
            return []
        }
    }

    private static func row(
        series: String?, label: String, units: Double,
        numberFormat: ActualNumberFormat, currencyCode: String,
        narrowSymbol: Bool, locale: Locale
    ) -> CustomReportChartAccessibilityRow {
        .init(series: series, label: label, value: amount(
            units: units, numberFormat: numberFormat, currencyCode: currencyCode,
            narrowSymbol: narrowSymbol, locale: locale))
    }

    static func amount(
        units: Double,
        numberFormat: ActualNumberFormat,
        currencyCode: String,
        narrowSymbol: Bool,
        locale: Locale
    ) -> String {
        CurrencyAmountFormat.string(
            cents: Int((units * 100).rounded()), currencyCode: currencyCode,
            narrowSymbol: narrowSymbol, numberFormat: numberFormat, locale: locale)
    }
}

enum ReportCurrencyAxisFormatting {
    static func label(
        units: Double,
        numberFormat: ActualNumberFormat,
        currencyCode: String,
        narrowSymbol: Bool,
        locale: Locale
    ) -> String {
        CustomReportChartAccessibility.amount(
            units: units,
            numberFormat: numberFormat,
            currencyCode: currencyCode,
            narrowSymbol: narrowSymbol,
            locale: locale)
    }

    static func hidesAxis(for hiddenBalances: Bool) -> Bool {
        hiddenBalances
    }
}

struct ReportCurrencyYAxis: ViewModifier {
    let numberFormat: ActualNumberFormat
    let currencyCode: String
    let narrowSymbol: Bool
    let locale: Locale
    let hidden: Bool

    func body(content: Content) -> some View {
        if ReportCurrencyAxisFormatting.hidesAxis(for: hidden) {
            content.chartYAxis(.hidden)
        } else {
            content.chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let units = value.as(Double.self) {
                            Text(ReportCurrencyAxisFormatting.label(
                                units: units, numberFormat: numberFormat,
                                currencyCode: currencyCode, narrowSymbol: narrowSymbol,
                                locale: locale))
                        }
                    }
                }
            }
        }
    }
}

struct CustomReportWidgetView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let data: CustomReportData

    /// Fixed cycle standing in for upstream's qualitative colour scale. Only
    /// the donut assigns colours itself: a category can share a name with its
    /// group, and `foregroundStyle(by:)` would merge the two.
    private static let palette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .yellow, .mint, .cyan, .brown, .red
    ]

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
                barChart(bars, signed: signed)
            }

        case .stacked(let stacked):
            if stacked.seriesNames.isEmpty {
                emptyText
            } else {
                Chart(points(stacked)) { point in
                    BarMark(
                        x: .value(ReportStrings.text("Interval", locale: locale), point.interval),
                        y: .value(ReportStrings.text("Amount", locale: locale), point.value)
                    )
                    .foregroundStyle(by: .value(ReportStrings.text("Group", locale: locale), point.series))
                }
                .chartLegend(.visible)
                .frame(height: 200)
                .modifier(ReportCurrencyYAxis(
                    numberFormat: budgetStore.numberFormat,
                    currencyCode: budgetStore.currencyCode,
                    narrowSymbol: budgetStore.useNarrowCurrencySymbol,
                    locale: locale,
                    hidden: budgetStore.hideBalances))
                .modifier(ChartAccessibility(
                    rows: chartAccessibilityRows(for: .stacked(stacked)),
                    hidden: budgetStore.hideBalances))
            }

        case .lines(let stacked, let trends):
            if stacked.seriesNames.isEmpty {
                emptyText
            } else {
                Chart {
                    ForEach(points(stacked)) { point in
                        LineMark(
                            x: .value(ReportStrings.text("Interval", locale: locale), point.interval),
                            y: .value(ReportStrings.text("Amount", locale: locale), point.value),
                            series: .value(ReportStrings.text("Series", locale: locale), point.series)
                        )
                        .foregroundStyle(by: .value(ReportStrings.text("Group", locale: locale), point.series))
                        PointMark(
                            x: .value(ReportStrings.text("Interval", locale: locale), point.interval),
                            y: .value(ReportStrings.text("Amount", locale: locale), point.value)
                        )
                        .foregroundStyle(by: .value(ReportStrings.text("Group", locale: locale), point.series))
                        .symbolSize(16)
                    }
                    // Upstream draws each series' least-squares trend as a
                    // dashed line in the series colour, from the first to the
                    // last interval.
                    ForEach(trendPoints(stacked, trends: trends)) { point in
                        LineMark(
                            x: .value(ReportStrings.text("Interval", locale: locale), point.interval),
                            y: .value(ReportStrings.text("Amount", locale: locale), point.value),
                            series: .value(ReportStrings.text("Series", locale: locale), "trend:" + point.series)
                        )
                        .foregroundStyle(by: .value(ReportStrings.text("Group", locale: locale), point.series))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .chartLegend(.visible)
                .frame(height: 200)
                .modifier(ReportCurrencyYAxis(
                    numberFormat: budgetStore.numberFormat,
                    currencyCode: budgetStore.currencyCode,
                    narrowSymbol: budgetStore.useNarrowCurrencySymbol,
                    locale: locale,
                    hidden: budgetStore.hideBalances))
                .modifier(ChartAccessibility(
                    rows: chartAccessibilityRows(for: .lines(stacked, trends: trends)),
                    hidden: budgetStore.hideBalances))
            }

        case .area(let bars):
            if bars.isEmpty {
                emptyText
            } else if bars.count < 2 {
                // An area has no width with one interval; show it as a bar.
                barChart(bars, signed: false)
            } else {
                Chart(Array(bars.enumerated()), id: \.offset) { _, bar in
                    AreaMark(
                        x: .value(ReportStrings.text("Interval", locale: locale), bar.label),
                        y: .value(ReportStrings.text("Amount", locale: locale), bar.valueUnits)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(
                        colors: [Color.accentColor.opacity(0.6), Color.accentColor.opacity(0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    LineMark(
                        x: .value(ReportStrings.text("Interval", locale: locale), bar.label),
                        y: .value(ReportStrings.text("Amount", locale: locale), bar.valueUnits)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
                }
                .frame(height: 180)
                .modifier(ReportCurrencyYAxis(
                    numberFormat: budgetStore.numberFormat,
                    currencyCode: budgetStore.currencyCode,
                    narrowSymbol: budgetStore.useNarrowCurrencySymbol,
                    locale: locale,
                    hidden: budgetStore.hideBalances))
                .modifier(ChartAccessibility(
                    rows: chartAccessibilityRows(for: .area(bars)),
                    hidden: budgetStore.hideBalances))
            }

        case .donut(let slices, let groups):
            if slices.isEmpty {
                emptyText
            } else {
                donut(slices: slices, groups: groups)
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
                            Text(budgetStore.displayBalance(cents(row.totalUnits), locale: locale))
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

    // MARK: - Donut

    /// Two rings are two overlaid charts rather than two mark sets in one:
    /// every SectorMark in a chart shares one angular stack, so a second ring
    /// inside the same chart would only get half the circle.
    private func donut(slices: [CustomReportData.Slice], groups: [CustomReportData.Bar]) -> some View {
        let colors = sliceColors(slices, groups: groups)
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if !groups.isEmpty {
                    Chart(Array(groups.enumerated()), id: \.offset) { i, group in
                        SectorMark(
                            angle: .value(ReportStrings.text("Amount", locale: locale), group.valueUnits),
                            innerRadius: .ratio(0.45),
                            outerRadius: .ratio(0.65),
                            angularInset: 1
                        )
                        .foregroundStyle(Self.palette[i % Self.palette.count])
                    }
                }
                Chart(Array(slices.enumerated()), id: \.offset) { i, slice in
                    SectorMark(
                        angle: .value(ReportStrings.text("Amount", locale: locale), slice.valueUnits),
                        innerRadius: .ratio(groups.isEmpty ? 0.6 : 0.68),
                        angularInset: 1
                    )
                    .foregroundStyle(colors[i])
                }
            }
            .frame(height: 180)
            .modifier(ChartAccessibility(
                rows: chartAccessibilityRows(for: .donut(slices: slices, groups: groups)),
                hidden: budgetStore.hideBalances))

            VStack(alignment: .leading, spacing: 4) {
                if groups.isEmpty {
                    ForEach(Array(slices.enumerated()), id: \.offset) { i, slice in
                        legendRow(color: colors[i], label: slice.label, units: slice.valueUnits)
                    }
                } else {
                    ForEach(Array(groups.enumerated()), id: \.offset) { gi, group in
                        legendRow(color: Self.palette[gi % Self.palette.count],
                                  label: group.label, units: group.valueUnits)
                        ForEach(Array(slices.enumerated()).filter { $0.element.group == gi },
                                id: \.offset) { i, slice in
                            legendRow(color: colors[i], label: slice.label,
                                      units: slice.valueUnits, indent: 14)
                        }
                    }
                }
            }
        }
    }

    /// Single ring: palette by position. Two rings: each category takes its
    /// group's colour lightened by position within the group, matching
    /// upstream's DonutGraph buildColorMap (0.15 + index / count * 0.5).
    private func sliceColors(_ slices: [CustomReportData.Slice], groups: [CustomReportData.Bar]) -> [Color] {
        guard !groups.isEmpty else {
            return slices.indices.map { Self.palette[$0 % Self.palette.count] }
        }
        var positionInGroup: [Int: Int] = [:]
        let groupSizes = Dictionary(grouping: slices.compactMap(\.group), by: { $0 }).mapValues(\.count)
        return slices.map { slice in
            let gi = slice.group ?? 0
            let k = positionInGroup[gi, default: 0]
            positionInGroup[gi] = k + 1
            let shade = 0.15 + Double(k) / Double(max(groupSizes[gi] ?? 1, 1)) * 0.5
            return Self.palette[gi % Self.palette.count].mix(with: .white, by: shade)
        }
    }

    private func legendRow(color: Color, label: String, units: Double, indent: CGFloat = 0) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).lineLimit(1)
            Spacer()
            Text(budgetStore.displayBalance(cents(units), locale: locale))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.leading, indent)
    }

    // MARK: - Helpers

    private func barChart(_ bars: [CustomReportData.Bar], signed: Bool) -> some View {
        Chart(Array(bars.enumerated()), id: \.offset) { _, bar in
            BarMark(
                x: .value(ReportStrings.text("Label", locale: locale), bar.label),
                y: .value(ReportStrings.text("Amount", locale: locale), bar.valueUnits)
            )
            .foregroundStyle(signed
                ? (bar.valueUnits < 0 ? Color.red : Color.green)
                : Color.accentColor)
        }
        .frame(height: 180)
        .modifier(ReportCurrencyYAxis(
            numberFormat: budgetStore.numberFormat,
            currencyCode: budgetStore.currencyCode,
            narrowSymbol: budgetStore.useNarrowCurrencySymbol,
            locale: locale,
            hidden: budgetStore.hideBalances))
        .modifier(ChartAccessibility(
            rows: chartAccessibilityRows(for: .bars(bars, signed: signed)),
            hidden: budgetStore.hideBalances))
    }

    private var emptyText: some View {
        Text(ReportStrings.text("No data in range", locale: locale))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
    }

    private func cents(_ units: Double) -> Int {
        Int((units * 100).rounded())
    }

    private func chartAccessibilityRows(for kind: CustomReportData.Kind) -> [CustomReportChartAccessibilityRow] {
        CustomReportChartAccessibility.rows(
            for: kind,
            numberFormat: budgetStore.numberFormat,
            currencyCode: budgetStore.currencyCode,
            narrowSymbol: budgetStore.useNarrowCurrencySymbol,
            locale: locale)
    }

    /// Flatten to (interval, series, value) points for Charts.
    private func points(_ stacked: CustomReportData.Stacked) -> [StackPoint] {
        stacked.seriesNames.enumerated().flatMap { s, name in
            stacked.intervalLabels.enumerated().map { i, label in
                StackPoint(interval: label, series: name, value: stacked.values[s][i])
            }
        }
    }

    private func trendPoints(_ stacked: CustomReportData.Stacked, trends: [CustomReportData.Trend]) -> [StackPoint] {
        guard let first = stacked.intervalLabels.first, let last = stacked.intervalLabels.last else { return [] }
        return zip(stacked.seriesNames, trends).flatMap { name, trend in
            [StackPoint(interval: first, series: name, value: trend.startUnits),
             StackPoint(interval: last, series: name, value: trend.endUnits)]
        }
    }

    private struct StackPoint: Identifiable {
        let interval: String
        let series: String
        let value: Double
        var id: String { interval + "|" + series }
    }

    private struct ChartAccessibility: ViewModifier {
        let rows: [CustomReportChartAccessibilityRow]
        let hidden: Bool

        func body(content: Content) -> some View {
            content
                .accessibilityHidden(hidden)
                .accessibilityRepresentation {
                    if !hidden {
                        VStack(alignment: .leading) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                HStack {
                                    if let series = row.series {
                                        Text(series)
                                    }
                                    Text(row.label)
                                    Text(row.value)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
        }
    }
}
