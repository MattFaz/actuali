import SwiftUI

struct BudgetLayoutButton: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    var body: some View {
        Menu {
            Picker("Layout", selection: $budgetStore.budgetDisplayStyle) {
                Label("Clean", systemImage: "list.bullet.rectangle").tag(BudgetDisplayStyle.clean)
                Label("Detailed", systemImage: "tablecells").tag(BudgetDisplayStyle.detailed)
                Label("Compact", systemImage: "rectangle.grid.1x2").tag(BudgetDisplayStyle.compact)
            }
        } label: {
            Image(systemName: "rectangle.grid.1x2")
        }
        .accessibilityLabel("Budget layout")
    }
}