import SwiftUI

struct SpendingWidgetView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let displayName: String
    let data: SpendingData
    let comparisonLabel: String

    private var delta: Int { data.currentSpentCents - data.comparisonCents }

    private var deltaColor: Color {
        if delta > 0 { return .red }    // spent more — bad
        if delta < 0 { return .green }  // spent less — good
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayName).font(.headline)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ReportStrings.text("This month", locale: locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(budgetStore.displayBalance(data.currentSpentCents, locale: locale))
                        .font(.title2.monospacedDigit())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(comparisonLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(budgetStore.displayBalance(data.comparisonCents, locale: locale))
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if data.comparisonCents != 0 {
                HStack(spacing: 4) {
                    Image(systemName: delta > 0 ? "arrow.up" : (delta < 0 ? "arrow.down" : "equal"))
                    Text(budgetStore.displayBalance(abs(delta), locale: locale))
                    Text(delta > 0 ? ReportStrings.text("more spent", locale: locale)
                        : (delta < 0 ? ReportStrings.text("less spent", locale: locale) : ""))
                }
                .font(.subheadline)
                .foregroundStyle(deltaColor)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
