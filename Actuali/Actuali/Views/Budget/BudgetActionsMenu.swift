import SwiftUI

/// The Budget tab's Actuali-mark menu for budget selection and budget item actions.
struct BudgetActionsMenu: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    @State private var budgetToUnlock: BudgetStore.RemoteBudget?

    var onNewCategory: () -> Void
    var canAddCategory = true
    var onNewGroup: () -> Void
    var onToggleReorder: () -> Void
    var onExpandAllGroups: () -> Void
    var onCollapseAllGroups: () -> Void
    var isReordering = false
    var showHiddenCategories: Binding<Bool>

    var body: some View {
        let localBudgets = BudgetFileManager.shared.listLocalBudgets()
        let currentLocalBudget = budgetStore.currentBudgetId.flatMap { currentID in
            localBudgets.first { $0.id == currentID }
        }
        let currentCloudFileID = currentLocalBudget?.cloudFileId
        let currentBudgetName = currentCloudFileID.flatMap { cloudFileID in
            budgetStore.remoteBudgets.first { $0.id == cloudFileID }?.name
        } ?? currentLocalBudget?.budgetName ?? String(localized: "Current Budget")

        Menu {
            if budgetStore.currentBudgetId != nil {
                budgetSelectionMenu(
                    currentBudgetName: currentBudgetName,
                    currentCloudFileID: currentCloudFileID
                )
            }

            Section {
                Button(action: onExpandAllGroups) {
                    Label(ReportStrings.text("Expand Groups", locale: locale, bundle: .main), systemImage: "chevron.down")
                }
                .accessibilityIdentifier("budgetActions.expandGroups")

                Button(action: onCollapseAllGroups) {
                    Label(ReportStrings.text("Collapse Groups", locale: locale, bundle: .main), systemImage: "chevron.right")
                }
                .accessibilityIdentifier("budgetActions.collapseGroups")
            }

            Section {
                Button(action: onNewCategory) {
                    Label("New Category", systemImage: "tag")
                }
                .disabled(!canAddCategory)

                Button(action: onNewGroup) {
                    Label("New Group", systemImage: "folder")
                }
                .accessibilityLabel("New Category Group")

                Button(action: onToggleReorder) {
                    Label(
                        isReordering ? "Done Reordering" : "Reorder Items",
                        systemImage: isReordering ? "checkmark" : "arrow.up.arrow.down"
                    )
                }
                .accessibilityIdentifier("budgetOptions.reorder")
            }

            Section {
                Toggle(isOn: showHiddenCategories) {
                    Label("Hidden Categories", systemImage: "eye")
                }
                .accessibilityLabel("Show Hidden Categories")
                .accessibilityIdentifier("budgetActions.showHiddenCategories")
            }
        } label: {
            Image("ActualiMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 23, height: 23)
        }
        .accessibilityLabel("Actuali menu")
        .accessibilityIdentifier("budget.actionsMenu")
        .sheet(item: $budgetToUnlock) { budget in
            EncryptionPasswordSheet(budget: budget, budgetStore: budgetStore)
        }
        .task(id: budgetStore.isConnected) {
            guard budgetStore.isConnected, budgetStore.remoteBudgets.isEmpty else { return }
            await budgetStore.fetchRemoteBudgets()
        }
    }

    private func budgetSelectionMenu(
        currentBudgetName: String,
        currentCloudFileID: String?
    ) -> some View {
        let hasCurrentRemoteBudget = currentCloudFileID.map { cloudFileID in
            budgetStore.remoteBudgets.contains { $0.id == cloudFileID }
        } ?? false

        return Menu {
            if !hasCurrentRemoteBudget {
                Button {} label: {
                    Label(currentBudgetName, systemImage: "checkmark")
                }
                .disabled(true)
                .accessibilityIdentifier("budgetActions.selectedBudget")
            }

            if budgetStore.remoteBudgets.isEmpty {
                if budgetStore.isConnected {
                    Button("Refresh Budgets") {
                        Task { await budgetStore.fetchRemoteBudgets() }
                    }
                    .disabled(budgetStore.isLoading)
                } else {
                    Button("Connect to server to switch budgets") {}
                        .disabled(true)
                }
            } else {
                ForEach(budgetStore.remoteBudgets) { budget in
                    let isCurrent = currentCloudFileID.map { budget.id == $0 } ?? false

                    Button {
                        selectBudget(budget, currentCloudFileID: currentCloudFileID)
                    } label: {
                        if isCurrent {
                            Label(budget.name, systemImage: "checkmark")
                        } else if budget.isEncrypted {
                            Label(budget.name, systemImage: "lock.fill")
                        } else {
                            Text(budget.name)
                        }
                    }
                    .accessibilityIdentifier("budgetActions.budget.\(budget.id)")
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    .disabled(isCurrent || budgetStore.downloadingBudgetId != nil)
                }
            }
        } label: {
            Label {
                // Keep the selector identity in the label's actual text.
                // SwiftUI can drop accessibilityLabel modifiers on nested Menu
                // controls, so the underlying label must carry both values.
                (Text("Current Budget") + Text(verbatim: ": \(currentBudgetName)"))
                    .lineLimit(1)
            } icon: {
                Image(systemName: "wallet.pass")
            }
        }
        .accessibilityIdentifier("budgetActions.budgetPicker")
    }

    private func selectBudget(
        _ budget: BudgetStore.RemoteBudget,
        currentCloudFileID: String?
    ) {
        if let currentCloudFileID, budget.id == currentCloudFileID {
            return
        }
        guard budgetStore.downloadingBudgetId == nil else { return }

        if budget.isEncrypted, EncryptionKeyManager.load(fileId: budget.id) == nil {
            budgetToUnlock = budget
        } else {
            Task { await budgetStore.downloadBudget(budget) }
        }
    }
}

#Preview {
    NavigationStack {
        Text("Budget")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BudgetActionsMenu(
                        onNewCategory: {},
                        onNewGroup: {},
                        onToggleReorder: {},
                        onExpandAllGroups: {},
                        onCollapseAllGroups: {},
                        showHiddenCategories: .constant(false)
                    )
                }
            }
    }
    .environmentObject(BudgetStore.previewInstance())
}
