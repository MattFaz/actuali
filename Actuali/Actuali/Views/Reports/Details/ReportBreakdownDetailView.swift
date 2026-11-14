import SwiftUI

/// A custom report with no intervals to chart, as a list: what each row is
/// worth and its share of the total. Donut and table reports map to this.
struct ReportBreakdown: Equatable {
    struct Row: Equatable {
        var name: String
        var value: Double
        /// The donut's colour for the row; nil on a table.
        var color: Color?
        /// The categories of a group row on a two-ring donut.
        var children: [Row] = []
    }

    var name: String
    var caption = ""
    var rows: [Row]
    var total: Double
    /// What to draw above the list; nil for a table.
    var donut: Donut?

    struct Donut: Equatable {
        var slices: [CustomReportData.Slice]
        var groups: [CustomReportData.Bar]
    }

    /// nil when there is no total to take a share of.
    func share(of row: Row) -> Double? {
        total == 0 ? nil : row.value / total
    }

    /// The rows a card has room to name: the largest by magnitude, in order.
    func leadingRows(limit: Int) -> [Int] {
        rows.indices.sorted { abs(rows[$0].value) > abs(rows[$1].value) }.prefix(limit).sorted()
    }
}

extension CustomReportData {
    var breakdown: ReportBreakdown? {
        let palette = CustomReportWidgetView.palette
        switch kind {
        case .donut(let slices, let groups) where !slices.isEmpty:
            let colors = ReportDonutChart.sliceColors(slices, groups: groups)
            func row(_ index: Int) -> ReportBreakdown.Row {
                .init(name: slices[index].label, value: slices[index].valueUnits, color: colors[index])
            }
            // Two rings list the groups, each over its categories.
            let rows = groups.isEmpty ? slices.indices.map(row) : groups.indices.map { group in
                ReportBreakdown.Row(name: groups[group].label, value: groups[group].valueUnits,
                                    color: palette[group % palette.count],
                                    children: slices.indices.filter { slices[$0].group == group }.map(row))
            }
            return ReportBreakdown(name: name, caption: rangeLabel, rows: rows,
                                   total: rows.reduce(0) { $0 + $1.value }, donut: .init(slices: slices, groups: groups))
        case .table(let rows, let totalUnits) where !rows.isEmpty:
            // Ranked: the card shows the report's own order.
            return ReportBreakdown(
                name: name, caption: rangeLabel,
                rows: rows.map { .init(name: $0.name, value: $0.totalUnits) }.sorted { abs($0.value) > abs($1.value) },
                total: totalUnits
            )
        default:
            return nil
        }
    }
}

/// Full-screen version of a donut or table card: the total, the donut, and
/// every row. Tapping a donut row picks its slice out.
struct ReportBreakdownDetailView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let breakdown: ReportBreakdown

    @State private var selected: Int?

    /// The row the readout describes, when one is picked.
    private var selectedRow: ReportBreakdown.Row? {
        selected.flatMap { breakdown.rows.indices.contains($0) ? breakdown.rows[$0] : nil }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ReportRangePicker()
                readout
                if let donut = breakdown.donut {
                    ReportDonutChart(slices: donut.slices, groups: donut.groups, highlighted: selected)
                        .frame(height: 220)
                        // The list below carries the same numbers as text.
                        .accessibilityHidden(true)
                }
                list
            }
            .padding()
        }
        .navigationTitle(breakdown.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !breakdown.caption.isEmpty {
                Text(breakdown.caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            Text(amount(selectedRow?.value ?? breakdown.total))
                .font(.system(size: 34, weight: .bold))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(selectedRow.map { row in [row.name, percent(row)].compactMap(\.self).joined(separator: " · ") }
                ?? ReportStrings.text("Total", locale: locale))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reportDetail.readout")
    }

    private var list: some View {
        let largest = breakdown.rows.map { abs($0.value) }.max() ?? 0
        return VStack(spacing: 0) {
            ForEach(breakdown.rows.indices, id: \.self) { index in
                if index > 0 {
                    Divider()
                }
                let row = breakdown.rows[index]
                if breakdown.donut != nil {
                    Button {
                        selected = selected == index ? nil : index
                    } label: {
                        VStack(spacing: 0) {
                            self.row(row).fontWeight(selected == index ? .semibold : .regular)
                            ForEach(Array(row.children.enumerated()), id: \.offset) { _, child in
                                self.row(child).padding(.leading, 18)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected == index ? .isSelected : [])
                    .accessibilityIdentifier("reportDetail.row.\(index)")
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        self.row(row, rank: index + 1)
                        if largest > 0, !budgetStore.hideBalances {
                            ProgressView(value: abs(row.value), total: largest)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ row: ReportBreakdown.Row, rank: Int? = nil) -> some View {
        HStack(spacing: 10) {
            if let rank {
                Text(rank.formatted(.number.locale(locale)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let color = row.color {
                Circle().fill(color).frame(width: 10, height: 10)
            }
            Text(row.name)
                .lineLimit(1)
            Spacer()
            Text(amount(row.value))
                .monospacedDigit()
            if row.children.isEmpty == false || breakdown.donut?.groups.isEmpty == true, let percent = percent(row) {
                Text(percent)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .frame(minHeight: 36)
    }

    /// Shares give the proportions away, so they hide with the amounts.
    private func percent(_ row: ReportBreakdown.Row) -> String? {
        guard !budgetStore.hideBalances, let share = breakdown.share(of: row) else { return nil }
        return share.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    private func amount(_ value: Double) -> String {
        budgetStore.displayBalance(Int((value * 100).rounded()), locale: locale)
    }
}
