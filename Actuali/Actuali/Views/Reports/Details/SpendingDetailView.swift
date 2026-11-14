import SwiftUI

/// This month's spending against each thing the widget can compare it with.
/// The card shows the one configured on the web; the detail page lists all
/// three.
struct SpendingComparisons: Equatable {
    static let modes: [SpendingMeta.Mode] = [.singleMonth, .budget, .average]

    let configured: SpendingMeta.Mode
    /// Parallel to `modes`.
    let byMode: [SpendingData]

    var card: SpendingData {
        byMode[Self.modes.firstIndex(of: configured) ?? 0]
    }

    static func compute(meta: SpendingMeta?, using engine: (SpendingMeta) -> SpendingData) -> SpendingComparisons {
        let base = meta ?? SpendingMeta(name: nil, conditions: nil, conditionsOp: nil, compare: nil,
                                        compareTo: nil, isLive: nil, mode: nil, averageRange: nil)
        return SpendingComparisons(
            // nil mode defaults to single-month upstream (SpendingCard.tsx).
            configured: base.mode ?? .singleMonth,
            byMode: modes.map { engine(base.with(mode: $0)) }
        )
    }
}

extension SpendingMeta {
    func with(mode: Mode) -> SpendingMeta {
        var copy = self
        copy.mode = mode
        return copy
    }
}

struct SpendingDetailView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let displayName: String
    let comparisons: SpendingComparisons
    /// Parallel to `SpendingComparisons.modes`.
    let labels: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ReportStrings.text("This month", locale: locale))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(budgetStore.displayBalance(comparisons.card.currentSpentCents, locale: locale))
                        .font(.system(size: 34, weight: .bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("reportDetail.readout")

                VStack(spacing: 0) {
                    ForEach(comparisons.byMode.indices, id: \.self) { index in
                        if index > 0 {
                            Divider()
                        }
                        row(labels[index], comparisons.byMode[index])
                    }
                }
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
    }

    private func row(_ label: String, _ data: SpendingData) -> some View {
        let delta = data.currentSpentCents - data.comparisonCents
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(budgetStore.displayBalance(data.comparisonCents, locale: locale))
                    .monospacedDigit()
            }
            .font(.subheadline)
            if data.comparisonCents != 0, delta != 0 {
                HStack(spacing: 4) {
                    Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                    Text(budgetStore.displayBalance(abs(delta), locale: locale))
                    Text(ReportStrings.text(delta > 0 ? "more spent" : "less spent", locale: locale))
                }
                .font(.footnote)
                // Spending more than the comparison is the bad direction.
                .foregroundStyle(delta > 0 ? .red : .green)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}
