import SwiftUI

struct SummaryWidgetView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    let displayName: String
    let data: SummaryData

    private var formatted: String {
        switch data.kind {
        case .currency:
            // Display absolute value; the color communicates direction. Matches
            // the webapp's Summary widget rendering (e.g., "$95,597.58" in red
            // for spending instead of "-$95,597.58").
            return budgetStore.formatCurrency(abs(data.totalCents))
        case .percentage:
            let number = abs(data.value).formatted(.number.precision(.fractionLength(0...2)))
            return "\(number)%"
        }
    }

    private var color: Color {
        if data.value > 0 { return .green }
        if data.value < 0 { return .red }
        return .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(formatted)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    VStack {
        SummaryWidgetView(displayName: "Spent This Month", data: SummaryData(value: -316310, kind: .currency))
        SummaryWidgetView(displayName: "Saved This Month", data: SummaryData(value: 1188352, kind: .currency))
        SummaryWidgetView(displayName: "Savings Rate", data: SummaryData(value: 27.15, kind: .percentage))
    }
    .padding()
    .environmentObject(BudgetStore.previewInstance())
}
