import SwiftUI
import Charts

struct NetWorthWidgetView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    let displayName: String
    let data: NetWorthData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(displayName).font(.headline)
                Spacer()
                if let last = data.points.last {
                    Text(budgetStore.displayBalanceWholeUnits(last.balanceCents))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if data.points.count >= 2 {
                Chart(data.points, id: \.date) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Balance", Double(point.balanceCents) / 100.0)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(
                        colors: [.green.opacity(0.6), .green.opacity(0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Balance", Double(point.balanceCents) / 100.0)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.green)
                }
                .frame(height: 180)
                // Keep the trend visible without exposing chart-axis amounts.
                .chartYAxis(budgetStore.hideBalances ? .hidden : .automatic)
                .accessibilityHidden(budgetStore.hideBalances)
            } else {
                Text("Not enough data")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
