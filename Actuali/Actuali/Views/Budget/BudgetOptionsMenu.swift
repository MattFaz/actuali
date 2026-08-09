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
            Picker("Layout", selection: $budgetStore.budgetDisplayStyle) {
                Label("Clean", systemImage: "list.bullet.rectangle")
                    .tag(BudgetDisplayStyle.clean)
                Label("Detailed", systemImage: "tablecells")
                    .tag(BudgetDisplayStyle.detailed)
            }
            .pickerStyle(.inline)

            if let expandAllGroups, let collapseAllGroups {
                Section {
                    Button(action: expandAllGroups) {
                        Label("Expand All Groups", systemImage: "chevron.down")
                    }
                    Button(action: collapseAllGroups) {
                        Label("Collapse All Groups", systemImage: "chevron.right")
                    }
                }
            }

            // Amount masking isn't here: it's app-wide, so it lives in
            // Settings (GH #158) rather than in any one tab's menu.
            Section {
                Toggle(isOn: $budgetStore.hideZeroBudgetCategories) {
                    Label("Hide Spent Categories", systemImage: "line.3.horizontal.decrease")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Budget options")
        .accessibilityHint("Layout, group and amount display options")
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
