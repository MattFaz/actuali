import SwiftUI

/// One-tap toolbar shortcut for Settings → Privacy → Hide Balances, like the
/// web app's privacy-mode eye. A toolbar button rather than a tap on the
/// amounts themselves: those taps already collapse sections and open sheets.
struct HideBalancesToggle: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    var body: some View {
        Toggle(isOn: $budgetStore.hideBalances) {
            Label(
                String(localized: "Hide Balances"),
                systemImage: budgetStore.hideBalances ? "eye.slash" : "eye"
            )
            .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .accessibilityIdentifier("toolbar.hideBalances")
    }
}
