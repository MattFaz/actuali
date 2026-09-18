import SwiftUI

enum BudgetCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case overspent
    case unassigned
    case approachingLimit
    case onTrack

    var id: Self { self }

    func includes(_ category: CategoryBudget) -> Bool {
        switch self {
        case .all:
            true
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
///
/// New Category / New Group used to be their own "+" toolbar button next to
/// this menu. Creation is still not a "how this looks" preference, but it's
/// the only other trailing-edge control the screen had, so folding it in here
/// keeps the toolbar down to one button; it sits in its own section at the
/// top, above the view options, so it reads as the odd one out rather than
/// blending into the layout controls beneath it.
struct BudgetOptionsMenu: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    /// nil when no budget is loaded — there's nothing to create a category or
    /// group into yet.
    var onNewCategory: (() -> Void)?
    /// A category needs a group to live in; false disables the action without
    /// hiding it, matching how the old "+" menu behaved.
    var canAddCategory = true
    var onNewGroup: (() -> Void)?

    /// Group actions are omitted when no budget is loaded — there are no
    /// groups to act on.
    var expandAllGroups: (() -> Void)?
    var collapseAllGroups: (() -> Void)?
    var onCopyPreviousMonthBudget: (() -> Void)?
    var onSetBudgetsToZero: (() -> Void)?
    /// Month-level goal-template actions (GH #371). nil hides the section —
    /// no budget loaded, or the goalTemplatesEnabled flag is off, mirroring
    /// the web's month menu behind its feature flag.
    var onTemplateAction: ((BudgetStore.GoalTemplateAction) -> Void)?
    var onCleanup: (() -> Void)?

    var body: some View {
        Menu {
            Section {
                if let onNewCategory {
                    Button(action: onNewCategory) {
                        Label("New Category", systemImage: "tag")
                    }
                    .disabled(!canAddCategory)
                }
                if let onNewGroup {
                    Button(action: onNewGroup) {
                        Label("New Group", systemImage: "folder")
                    }
                    .accessibilityLabel("New Category Group")
                }
            }

            Picker("Layout", selection: $budgetStore.budgetDisplayStyle) {
                Label("Clean", systemImage: "list.bullet.rectangle")
                    .tag(BudgetDisplayStyle.clean)
                Label("Compact", systemImage: "list.bullet")
                    .tag(BudgetDisplayStyle.compact)
            }
            .pickerStyle(.inline)

            if budgetStore.budgetDisplayStyle == .compact {
                Section {
                    Toggle(isOn: $budgetStore.showCompactBudgetOverview) {
                        Label("Show Overview", systemImage: "rectangle.topthird.inset.filled")
                    }
                    Toggle(isOn: $budgetStore.showCompactSpentColumn) {
                        Label("Show Spent", systemImage: "tablecells.badge.ellipsis")
                    }
                    .accessibilityLabel("Show Spent Column")
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

            if let onCopyPreviousMonthBudget {
                Section {
                    Button(action: onCopyPreviousMonthBudget) {
                        Label("Copy last month's budget", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("budget.copyPreviousMonthBudget")
                }
            }

            if let onSetBudgetsToZero {
                Section {
                    Button(action: onSetBudgetsToZero) {
                        Label("Set budgets to zero", systemImage: "0.circle")
                    }
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
                    if let onCleanup {
                        Button(action: onCleanup) {
                            Label("End of Month Cleanup", systemImage: "arrow.3.trianglepath")
                        }
                    }
                }
            }

            // Amount masking isn't here: it's app-wide, so it lives in
            // Settings (GH #158) rather than in any one tab's menu.
            Section {
                if budgetStore.budgetDisplayStyle != .clean {
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
                    Label("Hidden Categories", systemImage: "eye")
                }
                .accessibilityLabel("Show Hidden Categories")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Budget options")
        .accessibilityHint("Create categories and groups, change layout and display options")
    }
}

#Preview {
    NavigationStack {
        Text("Budget")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    BudgetOptionsMenu(
                        onNewCategory: {},
                        onNewGroup: {},
                        expandAllGroups: {},
                        collapseAllGroups: {}
                    )
                }
            }
    }
    .environmentObject(BudgetStore.previewInstance())
}
