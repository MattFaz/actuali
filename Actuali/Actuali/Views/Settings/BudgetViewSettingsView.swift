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

            // Mirrors the web's Settings → Experimental features toggle: the
            // flag is a synced preference, so flipping it here flips it for
            // every client on this budget.
            Section {
                Toggle("Budget Goal Templates", isOn: Binding(
                    get: { budgetStore.goalTemplatesEnabled },
                    set: { enabled in
                        Task { await budgetStore.setGoalTemplatesEnabled(enabled) }
                    }
                ))
                .disabled(budgetStore.currentBudgetId == nil)
                Toggle("Automations Editor", isOn: Binding(
                    get: { budgetStore.goalTemplatesUIEnabled },
                    set: { enabled in
                        Task { await budgetStore.setGoalTemplatesUIEnabled(enabled) }
                    }
                ))
                .disabled(budgetStore.currentBudgetId == nil || !budgetStore.goalTemplatesEnabled)
            } header: {
                Text("Experimental")
            } footer: {
                Text("Set budgeting goals per category with #template and #goal lines in category notes, or with the visual automations editor, then apply them from the Budget tab's options menu. Synced with the web app's Goal Templates experimental features.")
            }
        }
        .readableWidth()
        .navigationTitle("Budget View")
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
    }
}
