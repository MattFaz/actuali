import Foundation
import WidgetKit

extension BudgetStore {
    /// Writes the category-balance snapshot to the app group container and
    /// asks WidgetKit to redraw. Called after every data refresh and when a
    /// setting that changes amount formatting flips. No-op until a budget
    /// month is loaded, or when the build's provisioning lacks the app group.
    func publishWidgetSnapshot() {
        guard let store = WidgetSnapshotStore.standard(),
              let month = currentBudgetMonth else { return }
        let snapshot = WidgetSnapshot.make(
            from: month.categoryBudgets,
            balancesHidden: hideBalances,
            generatedAt: Date(),
            format: displayBalance
        )
        try? store.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Removes the snapshot so a disconnected device's widget shows the
    /// empty state instead of the departed budget's balances.
    func clearWidgetSnapshot() {
        guard let store = WidgetSnapshotStore.standard() else { return }
        store.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension WidgetSnapshot {
    /// Bridges the app's budget model to the widget snapshot. Formatting is
    /// injected so the mapping stays a pure function of its inputs.
    static func make(
        from budgets: [CategoryBudget],
        balancesHidden: Bool,
        generatedAt: Date,
        format: (Int) -> String
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: generatedAt,
            balancesHidden: balancesHidden,
            categories: budgets.map {
                WidgetCategoryBalance(
                    id: $0.categoryId,
                    name: $0.categoryName,
                    available: $0.available,
                    formattedAvailable: format($0.available)
                )
            }
        )
    }
}
