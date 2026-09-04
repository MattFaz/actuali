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
            Picker(String(localized: "Categories"), selection: $categoryFilter) {
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

            if budgetStore.budgetDisplayStyle == .compact {
                Section {
                    Toggle(isOn: $budgetStore.showCompactBudgetOverview) {
                        Label("Show Overview", systemImage: "rectangle.topthird.inset.filled")
                    }
                    Toggle(isOn: $budgetStore.showCompactSpentColumn) {
                        Label("Show Spent Column", systemImage: "tablecells.badge.ellipsis")
                    }
                }
            }

            Picker(String(localized: "budget.options.layout"), selection: $budgetStore.budgetDisplayStyle) {
                Label(String(localized: "budget.options.clean"), systemImage: "list.bullet.rectangle")
                    .tag(BudgetDisplayStyle.clean)
                Label(String(localized: "budget.options.detailed"), systemImage: "tablecells")
                    .tag(BudgetDisplayStyle.detailed)
                Label(String(localized: "budget.options.compact"), systemImage: "rectangle.grid.1x2")
                    .tag(BudgetDisplayStyle.compact)
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
            Image(systemName: categoryFilter == .all
                ? "ellipsis.circle"
                : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel(String(localized: "Budget options"))
        .accessibilityIdentifier("budget.options")
        .accessibilityHint(String(localized: "Layout, group and amount display options"))
    }
}

#Preview {
    NavigationStack {
        Text(String(localized: "navigation.budget"))
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
