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
                Picker(String(localized: "View Style"), selection: $budgetStore.budgetDisplayStyle) {
                    Text(String(localized: "Clean")).tag(BudgetDisplayStyle.clean)
                    Text(String(localized: "Detailed")).tag(BudgetDisplayStyle.detailed)
                    Text(String(localized: "Compact")).tag(BudgetDisplayStyle.compact)
                }

                Toggle(String(localized: "Group Totals"), isOn: $budgetStore.showGroupTotals)
                    .disabled(budgetStore.budgetDisplayStyle == .clean)

                Toggle(String(localized: "Status Filters"), isOn: $budgetStore.showBudgetCheckInStrip)
                Toggle(String(localized: "Hide Spent Categories"), isOn: $budgetStore.hideZeroBudgetCategories)
                Toggle(String(localized: "Category Status Dots"), isOn: $budgetStore.showCategoryStatusDots)
                Toggle(String(localized: "Budget Progress Bars"), isOn: $budgetStore.showBudgetProgressBars)
                Toggle(String(localized: "Overspent Badge"), isOn: $budgetStore.showOverspentBadge)
            } header: {
                Text(String(localized: "Presentation"))
            } footer: {
                if budgetStore.budgetDisplayStyle == .clean {
                    Text(String(localized: "Group Totals are available in Detailed and Compact views."))
                }
            }

            // Mirrors the web's Settings → Experimental features toggle: the
            // flag is a synced preference, so flipping it here flips it for
            // every client on this budget.
            Section {
                Toggle(String(localized: "Budget Goal Templates"), isOn: Binding(
                    get: { budgetStore.goalTemplatesEnabled },
                    set: { enabled in
                        Task { await budgetStore.setGoalTemplatesEnabled(enabled) }
                    }
                ))
                .disabled(budgetStore.currentBudgetId == nil)
                Toggle(String(localized: "Automations Editor"), isOn: Binding(
                    get: { budgetStore.goalTemplatesUIEnabled },
                    set: { enabled in
                        Task { await budgetStore.setGoalTemplatesUIEnabled(enabled) }
                    }
                ))
                .disabled(budgetStore.currentBudgetId == nil || !budgetStore.goalTemplatesEnabled)
            } header: {
                Text(String(localized: "Experimental"))
            } footer: {
                Text(String(localized: "Set budgeting goals per category with #template and #goal lines in category notes, or with the visual automations editor, then apply them from the Budget tab's options menu. Synced with the web app's Goal Templates experimental features."))
            }
        }
        .readableWidth()
        .navigationTitle(String(localized: "Budget View"))
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
    }
}
