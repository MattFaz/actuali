import Foundation
import WidgetKit

extension BudgetStore {
    /// Writes the category-balance snapshot to the app group container and
    /// asks WidgetKit to redraw. Called after every data refresh and when a
    /// setting that changes amount formatting flips. No-op until a budget
    /// month is loaded, or when the build's provisioning lacks the app group.
    func publishWidgetSnapshot() {
        guard !isPublishingReload, let store = widgetSnapshotStore,
              let month = widgetBudgetMonth else { return }
        let previous = lastWidgetSnapshot.flatMap { $0.url == store.fileURL ? $0.snapshot : nil }
        let snapshot = WidgetSnapshot.make(
            from: month.categoryBudgets,
            month: month.month,
            balancesHidden: hideBalances,
            generatedAt: Date(),
            format: displayBalance,
            accounts: accounts,
            budgetMonth: month,
            schedules: schedules,
            scheduleStatuses: scheduleStatuses,
            payees: payees
        )
        // Keep the footer's refresh time current without reloading unchanged balances.
        let contentChanged = snapshot.month != previous?.month
            || snapshot.balancesHidden != previous?.balancesHidden
            || snapshot.categories != previous?.categories
            || snapshot.accounts != previous?.accounts
            || snapshot.netWorth != previous?.netWorth
            || snapshot.toBudget != previous?.toBudget
            || snapshot.totalSpent != previous?.totalSpent
            || snapshot.upcomingBills != previous?.upcomingBills
        do {
            try store.write(snapshot)
            lastWidgetSnapshot = (store.fileURL, snapshot)
            if contentChanged {
                WidgetCenter.shared.reloadAllTimelines()
            }
        } catch {
            // Leave the last successful snapshot intact and retry next refresh.
        }
    }

    /// Removes the snapshot so a disconnected device's widget shows the
    /// empty state instead of the departed budget's balances.
    func clearWidgetSnapshot() {
        lastWidgetSnapshot = nil
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
        format: (Int) -> String,
        accounts: [Account] = [],
        budgetMonth: BudgetMonth? = nil,
        schedules: [ScheduleSummary] = [],
        scheduleStatuses: [String: ScheduleStatus] = [:],
        payees: [Payee] = []
    ) -> WidgetSnapshot {
        let sortedCategories = budgets
            .sorted { ($0.groupSortOrder, $0.categorySortOrder) < ($1.groupSortOrder, $1.categorySortOrder) }
            .map {
                WidgetCategoryBalance(
                    id: $0.categoryId,
                    name: $0.categoryName,
                    available: $0.available,
                    formattedAvailable: format($0.available)
                )
            }

        let openAccounts = accounts.filter { !$0.closed }
        let widgetAccounts = openAccounts
            .sorted { $0.sortOrder < $1.sortOrder }
            .map {
                WidgetAccountBalance(
                    id: $0.id,
                    name: $0.name,
                    balance: $0.balance,
                    formattedBalance: format($0.balance),
                    type: $0.type.rawValue,
                    offBudget: $0.offBudget
                )
            }

        let netWorth = openAccounts.reduce(0) { $0 + $1.balance }

        let payeeMap = Dictionary(payees.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let billItems = Self.buildUpcomingBills(
            schedules: schedules,
            statuses: scheduleStatuses,
            payeeMap: payeeMap,
            format: format
        )

        var snapshot = WidgetSnapshot(
            month: month,
            generatedAt: generatedAt,
            balancesHidden: balancesHidden,
            categories: sortedCategories
        )
        snapshot.accounts = widgetAccounts
        snapshot.netWorth = netWorth
        snapshot.formattedNetWorth = format(netWorth)
        snapshot.toBudget = budgetMonth?.toBudget
        snapshot.formattedToBudget = budgetMonth?.toBudget.map { format($0) }
        snapshot.totalBudgeted = budgetMonth?.totalBudgeted
        snapshot.formattedTotalBudgeted = budgetMonth.map { format($0.totalBudgeted) }
        snapshot.totalSpent = budgetMonth?.totalSpent
        snapshot.formattedTotalSpent = budgetMonth.map { format($0.totalSpent) }
        snapshot.totalIncome = budgetMonth?.totalIncome
        snapshot.formattedTotalIncome = budgetMonth.map { format($0.totalIncome) }
        snapshot.upcomingBills = billItems
        return snapshot
    }

    /// Extracts the next upcoming bills from schedules. Keeps it simple:
    /// non-completed schedules with a nextDate, sorted by date, capped at 8.
    private static func buildUpcomingBills(
        schedules: [ScheduleSummary],
        statuses: [String: ScheduleStatus],
        payeeMap: [String: String],
        format: (Int) -> String
    ) -> [WidgetBillItem] {
        schedules
            .filter { !$0.completed && $0.nextDate != nil }
            .sorted { ($0.nextDate ?? .distantFuture) < ($1.nextDate ?? .distantFuture) }
            .prefix(8)
            .map { schedule in
                let title = schedule.name
                    ?? schedule.payeeId.flatMap { payeeMap[$0] }
                    ?? "Scheduled"
                let date = schedule.nextDate!
                let status = statuses[schedule.id]
                let statusString = switch status {
                case .missed: "overdue"
                case .due: "due"
                default: "upcoming"
                }
                return WidgetBillItem(
                    id: schedule.id,
                    title: title,
                    amount: schedule.postAmount,
                    formattedAmount: format(abs(schedule.postAmount)),
                    dueDay: date.day,
                    dueMonth: date.month,
                    dueYear: date.year,
                    status: statusString
                )
            }
    }
}

private extension DayDate {
    static var distantFuture: DayDate {
        DayDate(year: 9999, month: 12, day: 31)
    }
}
