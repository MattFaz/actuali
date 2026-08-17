import SwiftUI

/// The Budget tab's single view-options control (GH #157).
///
/// Layout, expand/collapse and the spent-category filter used to be three
/// separate controls — two crowding the navigation bar and one stranded in a
/// footer section below the table. They all answer "how should this screen
/// look", so they live behind one menu; the navigation bar keeps only month
/// navigation.
struct BudgetOptionsMenu: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    /// Group actions are omitted when no budget is loaded — there are no
    /// groups to act on.
    var expandAllGroups: (() -> Void)?
    var collapseAllGroups: (() -> Void)?

    var body: some View {
        Menu {
            Picker(String(localized: "budget.options.layout"), selection: $budgetStore.budgetDisplayStyle) {
                Label(String(localized: "budget.options.clean"), systemImage: "list.bullet.rectangle")
                    .tag(BudgetDisplayStyle.clean)
                Label(String(localized: "budget.options.detailed"), systemImage: "tablecells")
                    .tag(BudgetDisplayStyle.detailed)
            }
            .pickerStyle(.inline)

            if let expandAllGroups, let collapseAllGroups {
                Section {
                    Button(action: expandAllGroups) {
                        Label(String(localized: "budget.options.expandAll"), systemImage: "chevron.down")
                    }
                    .accessibilityIdentifier("budget.expandAllGroups")
                    Button(action: collapseAllGroups) {
                        Label(String(localized: "budget.options.collapseAll"), systemImage: "chevron.right")
                    }
                    .accessibilityIdentifier("budget.collapseAllGroups")
                }
            }

            // Amount masking isn't here: it's app-wide, so it lives in
            // Settings (GH #158) rather than in any one tab's menu.
            Section {
                // Only the detailed style has columns for a group header to
                // total, so the clean style doesn't offer the switch.
                if budgetStore.budgetDisplayStyle == .detailed {
                    Toggle(isOn: $budgetStore.showGroupTotals) {
                        Label(String(localized: "budget.options.groupTotals"), systemImage: "sum")
                    }
                }
                Toggle(isOn: $budgetStore.hideZeroBudgetCategories) {
                        Label(String(localized: "budget.options.hideSpent"), systemImage: "line.3.horizontal.decrease")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(String(localized: "Budget options"))
        .accessibilityIdentifier("budget.options")
        .accessibilityHint(String(localized: "Layout, group and amount display options"))
    }
}

#Preview {
    NavigationStack {
        Text("Budget")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    BudgetOptionsMenu(expandAllGroups: {}, collapseAllGroups: {})
                }
            }
    }
    .environmentObject(BudgetStore.previewInstance())
}
