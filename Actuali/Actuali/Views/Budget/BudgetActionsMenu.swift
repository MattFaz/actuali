import SwiftUI

/// The Budget tab's sparkles button: the actions that change the month's
/// budget, kept apart from the view options in `BudgetOptionsMenu`.
struct BudgetActionsMenu: View {
    var onCopyPreviousMonthBudget: () -> Void
    var onSetBudgetsToZero: () -> Void
    /// Month-level goal-template actions (GH #371). nil hides the section
    /// when the goalTemplatesEnabled flag is off, mirroring the web's month
    /// menu behind its feature flag.
    var onTemplateAction: ((BudgetStore.GoalTemplateAction) -> Void)?
    var onCleanup: (() -> Void)?

    var body: some View {
        Menu {
            Section {
                Button(action: onCopyPreviousMonthBudget) {
                    Label("Copy last month's budget", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("budget.copyPreviousMonthBudget")
                Button(action: onSetBudgetsToZero) {
                    Label("Set budgets to zero", systemImage: "0.circle")
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
        } label: {
            Image(systemName: "sparkles")
        }
        .accessibilityLabel("Budget actions")
        .accessibilityIdentifier("budget.actionsMenu")
    }
}

#Preview {
    NavigationStack {
        Text("Budget")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    BudgetActionsMenu(
                        onCopyPreviousMonthBudget: {},
                        onSetBudgetsToZero: {},
                        onTemplateAction: { _ in },
                        onCleanup: {}
                    )
                }
            }
    }
}
