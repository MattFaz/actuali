import SwiftUI

enum BudgetCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case needsAttention
    case overspent
    case unassigned
    case approachingLimit
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
        case .approachingLimit:
            category.isApproachingLimit
        case .onTrack:
            category.progressState == .funded || category.progressState == .spending
        }
    }
}

/// The Budget tab's single view-options control (GH #157).
///
/// Layout, expand/collapse and the spent-category visibility toggle used to be three
/// separate controls — two crowding the navigation bar and one stranded in a
/// footer section below the table. The status filters themselves live in the
/// visible check-in strip rather than in here; only whether that strip is
/// shown is a view option.
struct BudgetOptionsMenu: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    /// Group actions are omitted when no budget is loaded — there are no
    /// groups to act on.
    var expandAllGroups: (() -> Void)?
    var collapseAllGroups: (() -> Void)?
    /// Month-level goal-template actions (GH #371). nil hides the section —
    /// no budget loaded, or the goalTemplatesEnabled flag is off, mirroring
    /// the web's month menu behind its feature flag.
    var onTemplateAction: ((BudgetStore.GoalTemplateAction) -> Void)?

    var body: some View {
        Menu {
            Picker("Layout", selection: $budgetStore.budgetDisplayStyle) {
                Label("Clean", systemImage: "list.bullet.rectangle")
                    .tag(BudgetDisplayStyle.clean)
                Label("Detailed", systemImage: "tablecells")
                    .tag(BudgetDisplayStyle.detailed)
                Label("List", systemImage: "rectangle.grid.1x2")
                    .tag(BudgetDisplayStyle.list)
            }
            .pickerStyle(.inline)

            if budgetStore.budgetDisplayStyle == .list {
                Section {
                    Toggle(isOn: $budgetStore.showListBudgetOverview) {
                        Label("Show Overview", systemImage: "rectangle.topthird.inset.filled")
                    }
                    Toggle(isOn: $budgetStore.showListSpentColumn) {
                        Label("Show Spent Column", systemImage: "tablecells.badge.ellipsis")
                    }
                }
            }

            if let expandAllGroups, let collapseAllGroups {
                Section {
                    Button(action: expandAllGroups) {
                        Label("Expand Groups", systemImage: "chevron.down")
                    }
                    .accessibilityLabel("Expand All Groups")
                    Button(action: collapseAllGroups) {
                        Label("Collapse Groups", systemImage: "chevron.right")
                    }
                    .accessibilityLabel("Collapse All Groups")
                }
            }

            // The web month menu's three template actions, in its order.
            if let onTemplateAction {
                Section {
                    Button {
                        onTemplateAction(.check)
                    } label: {
                        Label("Check Templates", systemImage: "checkmark.seal")
                    }
                    Button {
                        onTemplateAction(.apply)
                    } label: {
                        Label("Apply Budget Template", systemImage: "wand.and.stars")
                    }
                    Button {
                        onTemplateAction(.overwrite)
                    } label: {
                        Label("Overwrite with Budget Template", systemImage: "wand.and.stars.inverse")
                    }
                }
            }

            // Amount masking isn't here: it's app-wide, so it lives in
            // Settings (GH #158) rather than in any one tab's menu.
            Section {
                if budgetStore.budgetDisplayStyle.supportsGroupTotals {
                    Toggle(isOn: $budgetStore.showGroupTotals) {
                        Label("Group Totals", systemImage: "sum")
                    }
                }
                Toggle(isOn: $budgetStore.showBudgetCheckInStrip) {
                    Label("Status Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                Toggle(isOn: $budgetStore.hideZeroBudgetCategories) {
                    Label("Hide Spent", systemImage: "line.3.horizontal.decrease")
                }
                .accessibilityLabel("Hide Spent Categories")
                Toggle(isOn: $budgetStore.showHiddenCategories) {
                    Label("Show Hidden Categories", systemImage: "eye")
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
                    BudgetOptionsMenu(
                        expandAllGroups: {},
                        collapseAllGroups: {}
                    )
                }
            }
    }
    .environmentObject(BudgetStore.previewInstance())
}
