import SwiftUI
import Charts

struct CashFlowWidgetView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
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
                Bar(period: p.periodStart, kind: ReportStrings.text("Income", locale: locale), amount: Double(p.incomeCents) / 100),
                Bar(period: p.periodStart, kind: ReportStrings.text("Expense", locale: locale), amount: Double(p.expenseCents) / 100)
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
                Text(ReportStrings.text("No data", locale: locale))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                Chart(bars) { bar in
                    BarMark(
                        x: .value(ReportStrings.text("Period", locale: locale), bar.period, unit: .month),
                        y: .value(ReportStrings.text("Amount", locale: locale), bar.amount)
                    )
                    .foregroundStyle(by: .value(ReportStrings.text("Kind", locale: locale), bar.kind))
                    .position(by: .value(ReportStrings.text("Kind", locale: locale), bar.kind))
                }
                .chartForegroundStyleScale([
                    ReportStrings.text("Income", locale: locale): Color.green,
                    ReportStrings.text("Expense", locale: locale): Color.red
                ])
                .frame(height: 200)
                // The bars retain their trend, but hiding the numeric axis
                // prevents the chart from disclosing an exact amount.
                .modifier(ReportCurrencyYAxis(
                    numberFormat: budgetStore.numberFormat,
                    currencyCode: budgetStore.currencyCode,
                    narrowSymbol: budgetStore.useNarrowCurrencySymbol,
                    locale: locale,
                    hidden: budgetStore.hideBalances))
                .accessibilityHidden(budgetStore.hideBalances)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
