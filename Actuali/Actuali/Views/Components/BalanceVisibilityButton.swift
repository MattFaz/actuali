import SwiftUI

/// A shared navigation-bar control for the app-wide balance privacy setting.
///
/// Every tab reads the same `BudgetStore` instance, so toggling here masks
/// amounts everywhere at once. Keeping the control in one view prevents the
/// tabs' icons, labels, or behavior from drifting apart.
struct BalanceVisibilityButton: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    var body: some View {
        Button {
            budgetStore.hideBalances.toggle()
        } label: {
            Image(systemName: budgetStore.hideBalances ? "eye.slash" : "eye")
        }
        .accessibilityLabel(budgetStore.hideBalances ? "Show balances" : "Hide balances")
        .accessibilityHint("Hides amounts across the app")
    }
}

#Preview("Balances visible") {
    BalanceVisibilityButton()
        .environmentObject(BudgetStore.previewInstance())
}
