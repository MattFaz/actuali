import SwiftUI

struct FormulaWidgetView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    let displayName: String
    let result: FormulaEngine.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayName).font(.headline)
            switch result {
            case .value(let units):
                Text(budgetStore.displayBalance(Int((units * 100).rounded())))
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(units < 0 ? Color.red : Color.green)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            case .unsupported(let reason):
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
