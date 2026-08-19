import Foundation
import WidgetKit

extension BudgetStore {
    /// Writes the category-balance snapshot to the app group container and
    /// asks WidgetKit to redraw. Called after every data refresh and when a
    /// setting that changes amount formatting flips. No-op until a budget
    /// month is loaded, or when the build's provisioning lacks the app group.
    func publishWidgetSnapshot() {
        guard let store = widgetSnapshotStore,
              let month = widgetBudgetMonth else { return }
        let snapshot = WidgetSnapshot.make(
            from: month.categoryBudgets,
            month: month.month,
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
        guard let store = widgetSnapshotStore else { return }
        store.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension WidgetSnapshot {
    /// Bridges the app's budget model to the widget snapshot. Formatting is
    /// injected so the mapping stays a pure function of its inputs. Sorted
    /// the way the Budget tab sorts — fetchBudgetMonth gives no order
    /// guarantee, and the widget's unconfigured fallback shows the first
    /// few categories.
    static func make(
        from budgets: [CategoryBudget],
        month: String,
        balancesHidden: Bool,
        generatedAt: Date,
        format: (Int) -> String
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            month: month,
            generatedAt: generatedAt,
            balancesHidden: balancesHidden,
            categories: budgets
                .sorted { ($0.groupSortOrder, $0.categorySortOrder) < ($1.groupSortOrder, $1.categorySortOrder) }
                .map {
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
