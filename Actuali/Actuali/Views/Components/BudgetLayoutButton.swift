import SwiftUI

/// Toolbar control on the Budget tab that flips between the clean card
/// layout and the detailed PWA-style table (actios-96wa). The icon shows
/// the current layout; tapping switches to the other one.
struct BudgetLayoutButton: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    var body: some View {
        Button {
            budgetStore.budgetDisplayStyle =
                budgetStore.budgetDisplayStyle == .clean ? .detailed : .clean
        } label: {
            Image(systemName: budgetStore.budgetDisplayStyle == .clean
                ? "list.bullet.rectangle"
                : "tablecells")
        }
        .accessibilityLabel(budgetStore.budgetDisplayStyle == .clean
            ? "Switch to detailed layout"
            : "Switch to clean layout")
        .accessibilityHint("Changes how budget categories are displayed")
    }
}

#Preview {
    BudgetLayoutButton()
        .environmentObject(BudgetStore.previewInstance())
}
