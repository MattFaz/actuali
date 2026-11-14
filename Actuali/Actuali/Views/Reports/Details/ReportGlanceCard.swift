import SwiftUI

/// The dashboard card for a chart widget: the one number that answers it, a
/// sketch of the chart, and a short legend. The detail page has the rest.
struct ReportGlanceCard: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    @Environment(\.reportCardLinksToDetail) private var linksToDetail
    let detail: ReportChartDetail

    private static let legendLimit = 3

    private var latest: Int {
        detail.intervals.count - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.name).font(.headline)
                    if !detail.caption.isEmpty {
                        Text(detail.caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if linksToDetail {
                    // Decorative: the card itself is the button.
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            if let headline {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(headline.text)
                        .font(.system(size: 30, weight: .bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .foregroundStyle(headline.color)
                    context
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ReportDetailChart(detail: detail)
                .accessibilityHidden(true)
            legend
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Headline

    private var headline: (text: String, color: Color)? {
        if let text = detail.card.text {
            return (text, .primary)
        }
        guard let value = detail.card.value ?? detail.readoutValue(at: latest) else { return nil }
        // A difference is good or bad by its sign.
        let signed = detail.readout == .difference && detail.card.value == nil && !budgetStore.hideBalances
        return (amount(value, compact: detail.card.compact), signed ? (value < 0 ? .red : .green) : .primary)
    }

    @ViewBuilder
    private var context: some View {
        if let context = detail.card.context {
            Text(context)
        } else if detail.card.showsChange, let first = detail.series[0].values.first, !budgetStore.hideBalances {
            let change = detail.series[0].values[latest] - first
            Text((change < 0 ? "▼ " : "▲ ") + amount(abs(change), compact: detail.card.compact))
                .foregroundStyle(change < 0 ? .red : .green)
        } else {
            Text([detail.readoutLabel, detail.intervals[latest]].filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }

    // MARK: - Legend

    @ViewBuilder
    private var legend: some View {
        if detail.canHideSeries {
            // Too many to name them all: the largest few, with their amounts.
            let leading = detail.leadingSeries(limit: Self.legendLimit)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(leading, id: \.self) { index in
                    HStack(spacing: 8) {
                        Circle().fill(detail.series[index].color).frame(width: 8, height: 8)
                        Text(detail.series[index].name).lineLimit(1)
                        Spacer()
                        Text(amount(detail.series[index].values[latest])).monospacedDigit()
                    }
                    .font(.subheadline)
                }
                if detail.series.count > leading.count {
                    Text(ReportStrings.localized("…and \(detail.series.count - leading.count) more", locale: locale))
                        .font(.footnote)
                        .foregroundStyle(.tint)
                }
            }
        } else if detail.showsInlineLegend || detail.band != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { swatches }
                VStack(alignment: .leading, spacing: 4) { swatches }
            }
        }
    }

    @ViewBuilder
    private var swatches: some View {
        ForEach(detail.series.indices, id: \.self) { index in
            swatch(detail.series[index].name, detail.series[index].color)
        }
        if let band = detail.band {
            swatch(band.lowerName + " - " + band.upperName, band.color.opacity(0.35))
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 4)
            Text(name).lineLimit(1)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func amount(_ value: Double, compact: Bool = false) -> String {
        detail.text(for: value, compact: compact, store: budgetStore, locale: locale)
    }
}
