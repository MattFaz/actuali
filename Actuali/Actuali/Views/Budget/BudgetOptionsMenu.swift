import SwiftUI

enum BudgetCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case needsAttention
    case overspent
    case unassigned
    case onTrack

    var id: Self { self }

    func includes(_ category: CategoryBudget) -> Bool {
        switch self {
        case .all:
            true
        case .needsAttention:
            category.progressState == .overspent || category.progressState == .unassigned
        case .overspent:
            category.progressState == .overspent
        case .unassigned:
            category.progressState == .unassigned
        case .onTrack:
            category.progressState == .funded || category.progressState == .spending
        }
    }
}

/// The Budget tab's single view-options control (GH #157).
///
/// Layout, expand/collapse and the spent-category filter used to be three
/// separate controls — two crowding the navigation bar and one stranded in a
/// footer section below the table. They all answer "how should this screen
/// look", so they live behind one menu; the navigation bar keeps only month
/// navigation.
struct BudgetOptionsMenu: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    @Binding var categoryFilter: BudgetCategoryFilter
    var isTrackingBudget = false

    /// Group actions are omitted when no budget is loaded — there are no
    /// groups to act on.
    var expandAllGroups: (() -> Void)?
    var collapseAllGroups: (() -> Void)?

    var body: some View {
        Menu {
            Picker("Categories", selection: $categoryFilter) {
                Label("All Categories", systemImage: "list.bullet")
                    .tag(BudgetCategoryFilter.all)
                Label("Needs Attention", systemImage: "exclamationmark.circle")
                    .tag(BudgetCategoryFilter.needsAttention)
                Label(isTrackingBudget ? "Over Budget" : "Overspent", systemImage: "exclamationmark.triangle")
                    .tag(BudgetCategoryFilter.overspent)
                Label(isTrackingBudget ? "No Budget Set" : "Not Funded", systemImage: "circle.dashed")
                    .tag(BudgetCategoryFilter.unassigned)
                Label(isTrackingBudget ? "Within Budget" : "On Track", systemImage: "checkmark.circle")
                    .tag(BudgetCategoryFilter.onTrack)
            }
            .pickerStyle(.inline)

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
                // Only the detailed style has columns for a group header to
                // total, so the clean style doesn't offer the switch.
                if budgetStore.budgetDisplayStyle == .detailed {
                    Toggle(isOn: $budgetStore.showGroupTotals) {
                        Label("Group Totals", systemImage: "sum")
                    }
                }
                Toggle(isOn: $budgetStore.hideZeroBudgetCategories) {
                    Label("Hide Spent Categories", systemImage: "line.3.horizontal.decrease")
                }
            }
        } label: {
            Image(systemName: categoryFilter == .all
                ? "ellipsis.circle"
                : "line.3.horizontal.decrease.circle.fill")
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
                    BudgetOptionsMenu(
                        categoryFilter: .constant(.all),
                        expandAllGroups: {},
                        collapseAllGroups: {}
                    )
                }
            }
    }
    .environmentObject(BudgetStore.previewInstance())
}
