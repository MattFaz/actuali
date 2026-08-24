import SwiftUI

struct BudgetViewSettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    var body: some View {
        Form {
            // The Budget options menu keeps these as contextual shortcuts;
            // Settings exposes the same store-backed preferences so they can
            // also be managed outside the Budget tab.
            // #GH-332 is an issue for adding customizablity to this to prevent redundancy
            Section {
                Picker("View Style", selection: $budgetStore.budgetDisplayStyle) {
                    Text("Clean").tag(BudgetDisplayStyle.clean)
                    Text("Detailed").tag(BudgetDisplayStyle.detailed)
                }

                Toggle("Group Totals", isOn: $budgetStore.showGroupTotals)
                    .disabled(budgetStore.budgetDisplayStyle != .detailed)

                Toggle("Status Filters", isOn: $budgetStore.showBudgetCheckInStrip)
                Toggle("Hide Spent Categories", isOn: $budgetStore.hideZeroBudgetCategories)
                Toggle("Category Status Dots", isOn: $budgetStore.showCategoryStatusDots)
                Toggle("Budget Progress Bars", isOn: $budgetStore.showBudgetProgressBars)
                Toggle("Overspent Badge", isOn: $budgetStore.showOverspentBadge)
            } header: {
                Text("Presentation")
            } footer: {
                if budgetStore.budgetDisplayStyle == .clean {
                    Text("Group Totals are available in Detailed view.")
                }
            }
        }
        .readableWidth()
        .navigationTitle("Budget View")
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
    }
}
