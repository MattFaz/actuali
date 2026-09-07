import SwiftUI
import Charts

struct NetWorthWidgetView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let displayName: String
    let data: NetWorthData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(displayName).font(.headline)
                Spacer()
                if let last = data.points.last {
                    Text(budgetStore.displayBalanceWholeUnits(last.balanceCents, locale: locale))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if data.points.count >= 2 {
                Chart(data.points, id: \.date) { point in
                    AreaMark(
                        x: .value(ReportStrings.text("Date", locale: locale), point.date),
                        y: .value(ReportStrings.text("Balance", locale: locale), Double(point.balanceCents) / 100.0)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(
                        colors: [.green.opacity(0.6), .green.opacity(0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    LineMark(
                        x: .value(ReportStrings.text("Date", locale: locale), point.date),
                        y: .value(ReportStrings.text("Balance", locale: locale), Double(point.balanceCents) / 100.0)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.green)
                }
                .frame(height: 180)
                // Keep the trend visible without exposing chart-axis amounts.
                .modifier(ReportCurrencyYAxis(
                    numberFormat: budgetStore.numberFormat,
                    currencyCode: budgetStore.currencyCode,
                    narrowSymbol: budgetStore.useNarrowCurrencySymbol,
                    locale: locale,
                    hidden: budgetStore.hideBalances))
                .accessibilityHidden(budgetStore.hideBalances)
            } else {
                Text(ReportStrings.text("Not enough data", locale: locale))
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
