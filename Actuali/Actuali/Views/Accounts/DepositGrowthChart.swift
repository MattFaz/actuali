import Charts
import SwiftUI

/// Value against money paid in, over a deposit's whole term.
///
/// Two series rather than three: the interest is the gap between them, which
/// is easier to read than a third line and needs no extra legend entry. The
/// value line steps at each compounding period because that is when the bank
/// actually credits interest — `.stepEnd` says so rather than smoothing it
/// into a curve the statement won't match.
struct DepositGrowthChart: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.locale) private var locale

    let config: DepositConfig

    var body: some View {
        let points = DepositGrowth.curve(config)
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value(String(localized: "Month"), point.month.utcDate),
                    y: .value(String(localized: "Value"), Double(point.deposited) / 100.0),
                    series: .value(String(localized: "Series"), String(localized: "Deposited"))
                )
                .interpolationMethod(.stepEnd)
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            ForEach(points) { point in
                LineMark(
                    x: .value(String(localized: "Month"), point.month.utcDate),
                    y: .value(String(localized: "Value"), Double(point.value) / 100.0),
                    series: .value(String(localized: "Series"), String(localized: "Value"))
                )
                .interpolationMethod(.stepEnd)
                .foregroundStyle(Color.accentColor)
            }
        }
        .frame(height: 180)
        .modifier(ReportCurrencyYAxis(
            numberFormat: budgetStore.numberFormat,
            currencyCode: budgetStore.currencyCode,
            narrowSymbol: budgetStore.useNarrowCurrencySymbol,
            locale: locale,
            hidden: budgetStore.hideBalances
        ))
        .accessibilityHidden(budgetStore.hideBalances)
    }
}
