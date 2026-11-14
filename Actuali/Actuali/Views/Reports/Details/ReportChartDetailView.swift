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
    @State private var showsTotal = true

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
                ReportRangePicker()
                if detail.canShowTotal {
                    Picker(ReportStrings.text("Chart view", locale: locale), selection: $showsTotal) {
                        Text(ReportStrings.text("Total", locale: locale)).tag(true)
                        Text(ReportStrings.text("Breakdown", locale: locale)).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("reportDetail.chartView")
                }
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
                if !detail.events.isEmpty {
                    eventsList
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
            if !detail.rangeCaption.isEmpty {
                Text(detail.rangeCaption)
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
        // The total already leaves the hidden series out.
        let total = showsTotal && detail.canShowTotal
        let shown = total ? detail.totalled(hiding: hidden) : detail
        let figures = shown.figures(hiding: total ? [] : hidden)
        return ReportDetailChart(detail: shown, hidden: total ? [] : hidden, selection: $selected)
            // The interval list below already reads every figure. The other
            // lists carry one interval, and VoiceOver can't drag to move it,
            // so there the chart stands in for the whole table.
            .accessibilityHidden(breakdown == .intervals || budgetStore.hideBalances)
            .accessibilityRepresentation {
                VStack(alignment: .leading) {
                    ForEach(figures.indices, id: \.self) { index in
                        Text(verbatim: [figures[index].series, figures[index].interval, amount(figures[index].value)]
                            .joined(separator: ", "))
                    }
                }
            }
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

    private var eventsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ReportStrings.text("Upcoming", locale: locale))
                .font(.headline)
                .padding([.horizontal, .top])
                .padding(.bottom, 8)
            ForEach(Array(detail.events.enumerated()), id: \.offset) { _, event in
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.name)
                            .lineLimit(1)
                        Text(event.date)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(amount(event.amount))
                        .monospacedDigit()
                }
                .font(.subheadline)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("reportDetail.events")
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

    private func amount(_ value: Double) -> String {
        detail.text(for: value, store: budgetStore, locale: locale)
    }
}
