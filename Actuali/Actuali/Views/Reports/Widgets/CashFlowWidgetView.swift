import SwiftUI
import Charts

struct CashFlowWidgetView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    let displayName: String
    let data: CashFlowData

    private struct Bar: Identifiable {
        let period: Date
        let kind: String
        let amount: Double

        var id: String { "\(kind)-\(period.timeIntervalSinceReferenceDate)" }
    }

    private var bars: [Bar] {
        data.points.flatMap { p in
            [
                Bar(period: p.periodStart, kind: "Income", amount: Double(p.incomeCents) / 100),
                Bar(period: p.periodStart, kind: "Expense", amount: Double(p.expenseCents) / 100)
            ]
        }
    }

    private var allEmpty: Bool {
        data.points.allSatisfy { $0.incomeCents == 0 && $0.expenseCents == 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayName).font(.headline)
            if data.points.isEmpty || allEmpty {
                Text("No data")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                Chart(bars) { bar in
                    BarMark(
                        x: .value("Period", bar.period, unit: .month),
                        y: .value("Amount", bar.amount)
                    )
                    .foregroundStyle(by: .value("Kind", bar.kind))
                    .position(by: .value("Kind", bar.kind))
                }
                .chartForegroundStyleScale([
                    "Income": Color.green,
                    "Expense": Color.red
                ])
                .frame(height: 200)
                // The bars retain their trend, but hiding the numeric axis
                // prevents the chart from disclosing an exact amount.
                .chartYAxis(budgetStore.hideBalances ? .hidden : .automatic)
                .accessibilityHidden(budgetStore.hideBalances)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
