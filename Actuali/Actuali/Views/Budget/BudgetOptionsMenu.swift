import SwiftUI

enum BudgetCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case overspent
    case unassigned
    case approachingLimit
    case onTrack

    var id: Self {
        self
    }

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

/// The ellipsis menu groups display preferences and budget actions.
struct BudgetOptionsMenu: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    var onCopyPreviousMonthBudget: (() -> Void)?
    var onSetBudgetsToZero: (() -> Void)?
    var onTemplateAction: ((BudgetStore.GoalTemplateAction) -> Void)?
    var onCleanup: (() -> Void)?
    var monthNote: EntityNote = .unsupported
    var onEditMonthNote: (() -> Void)?

    private var hasAnyActions: Bool {
        let hasBudgetActions = onCopyPreviousMonthBudget != nil && onSetBudgetsToZero != nil
        return hasBudgetActions || onCleanup != nil || onTemplateAction != nil
    }

    var body: some View {
        Menu {
            Menu("Style") {
                Picker("Style", selection: $budgetStore.budgetDisplayStyle) {
                    Label("Clean", systemImage: "list.bullet.rectangle")
                        .tag(BudgetDisplayStyle.clean)
                    Label("Compact", systemImage: "list.bullet")
                        .tag(BudgetDisplayStyle.compact)
                }
                .pickerStyle(.inline)
            }

            Menu("Budget View") {
                Section {
                    Toggle(isOn: budgetStore.budgetDisplayStyle == .clean
                        ? $budgetStore.showCleanBudgetOverview
                        : $budgetStore.showCompactBudgetOverview) {
                            Label("Show Overview", systemImage: "rectangle.topthird.inset.filled")
                        }
                        .accessibilityIdentifier("budgetOptions.showOverview")
                    Toggle(isOn: $budgetStore.showBudgetedAmounts) {
                        Label("Show Budgeted", systemImage: "banknote")
                    }
                    .accessibilityLabel("Budgeted Amounts")
                    .accessibilityIdentifier("budgetOptions.showBudgetedAmounts")
                    Toggle(isOn: $budgetStore.showCompactSpentColumn) {
                        Label("Show Spent", systemImage: "tablecells.badge.ellipsis")
                    }
                    .accessibilityLabel("Show Spent Column")
                    .disabled(budgetStore.budgetDisplayStyle != .compact)
                    Toggle(isOn: $budgetStore.showGroupTotals) {
                        Label("Group Totals", systemImage: "sum")
                    }
                    .disabled(budgetStore.budgetDisplayStyle == .clean)
                    Toggle(isOn: $budgetStore.showBudgetCheckInStrip) {
                        Label("Status Filters", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    Toggle(isOn: $budgetStore.hideZeroBudgetCategories) {
                        Label("Hide Spent", systemImage: "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("Hide Spent Categories")
                }
            }

            if hasAnyActions {
                Menu("Actions") {
                    if let onCopyPreviousMonthBudget, let onSetBudgetsToZero {
                        Section {
                            Button(action: onCopyPreviousMonthBudget) {
                                Label("Copy last month's budget", systemImage: "doc.on.doc")
                            }
                            .accessibilityIdentifier("budget.copyPreviousMonthBudget")
                            Button(action: onSetBudgetsToZero) {
                                Label("Set budgets to zero", systemImage: "0.circle")
                            }
                        }
                    }
    
                    if let onCleanup {
                        Section {
                            Button(action: onCleanup) {
                                Label("End of Month Cleanup", systemImage: "arrow.3.trianglepath")
                            }
                            .disabled(!budgetStore.goalTemplatesEnabled)
                        }
                    }
    
                    if let onTemplateAction {
                        Section {
                            Button { onTemplateAction(.check) } label: {
                                Label("Check Templates", systemImage: "checkmark.seal")
                            }
                            .disabled(!budgetStore.goalTemplatesEnabled)
                            Button { onTemplateAction(.apply) } label: {
                                Label("Apply Budget Template", systemImage: "wand.and.stars")
                            }
                            .disabled(!budgetStore.goalTemplatesEnabled)
                            Button { onTemplateAction(.overwrite) } label: {
                                Label("Overwrite with Budget Template", systemImage: "wand.and.stars.inverse")
                            }
                            .disabled(!budgetStore.goalTemplatesEnabled)
                        }
                    }
                }
            }

            if let onEditMonthNote, monthNote.supported {
                Button(action: onEditMonthNote) {
                    if monthNote.isEmpty {
                        Label("Add Note", systemImage: "note.text.badge.plus")
                    } else {
                        Label("Edit Note", systemImage: "note.text")
                        Text(monthNote.text)
                    }
                }
                .accessibilityIdentifier("budget.monthNote")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Budget options")
    }
}

#Preview {
    NavigationStack {
        Text("Budget")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    BudgetOptionsMenu(
                        onCopyPreviousMonthBudget: {},
                        onSetBudgetsToZero: {},
                        onTemplateAction: { _ in },
                        onCleanup: {}
                    )
                }
            }
    }
    .environmentObject(BudgetStore.previewInstance())
}
