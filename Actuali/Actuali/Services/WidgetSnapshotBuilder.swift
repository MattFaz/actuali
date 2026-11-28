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
            payees: payees,
            transactions: transactions,
            monthToDateSpending: widgetMonthToDateSpending
        )
        // Keep the footer's refresh time current without reloading unchanged balances.
        var comparable = snapshot
        comparable.generatedAt = previous?.generatedAt ?? .distantPast
        let contentChanged = comparable != previous
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

/// Net spending per category (negative = spending) for this month and last,
/// each from its 1st through today's day number, so Spending vs Last Month
/// compares like for like. A category with no transactions in its window has
/// no key; an empty lastMonth means nothing to compare.
struct MonthToDateSpending: Equatable {
    var thisMonth: [String: Int]
    var lastMonth: [String: Int]
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
        payees: [Payee] = [],
        transactions: [Transaction] = [],
        monthToDateSpending: MonthToDateSpending? = nil
    ) -> WidgetSnapshot {
        let comparison = monthToDateSpending.flatMap { $0.lastMonth.isEmpty ? nil : $0 }
        let sortedCategories = budgets
            .sorted { ($0.groupSortOrder, $0.categorySortOrder) < ($1.groupSortOrder, $1.categorySortOrder) }
            .map {
                // Spending vs Last Month's movers, signed like spendingDifference;
                // a category quiet in either window compares against nothing spent.
                let id = $0.categoryId
                let difference = comparison.map { $0.lastMonth[id, default: 0] - $0.thisMonth[id, default: 0] }
                return WidgetCategoryBalance(
                    id: $0.categoryId,
                    name: $0.categoryName,
                    available: $0.available,
                    formattedAvailable: format($0.available),
                    budgeted: $0.budgeted,
                    spent: balancesHidden ? 0 : $0.spent,
                    formattedSpent: format(-$0.spent),
                    formattedBudgeted: format($0.budgeted),
                    spendingDifference: balancesHidden ? difference.map { _ in 0 } : difference,
                    formattedSpendingDifference: difference.map(format)
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
        let activeAccountIds = Set(openAccounts.map(\.id))
        let billItems = Self.buildUpcomingBills(
            schedules: schedules,
            statuses: scheduleStatuses,
            activeAccountIds: activeAccountIds,
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
        snapshot.formattedTotalSpending = budgetMonth.map { format(-$0.totalSpent) }
        snapshot.formattedTotalIncome = budgetMonth.map { format($0.totalIncome) }
        snapshot.upcomingBills = billItems
        snapshot.addTransactions(
            transactions,
            accounts: accounts,
            hiddenCategoryIds: Set(budgetMonth.map { $0.hiddenCategoryBudgets.map(\.categoryId) + $0.hiddenIncomeCategories.map(\.categoryId) } ?? []),
            format: format
        )
        if let comparison {
            snapshot.addMonthComparison(comparison, format: format)
        }
        if let budgetMonth {
            snapshot.addDailyRates(budgetMonth, now: generatedAt, format: format)
        }
        return snapshot
    }

    /// `format` already masks when balances are hidden; the raw cents are
    /// zeroed as well so nothing leaks through the unformatted fields. Hidden
    /// categories' names are blanked whatever the mask, matching the
    /// category rows, which leave hidden categories out entirely.
    private mutating func addTransactions(
        _ transactions: [Transaction],
        accounts: [Account],
        hiddenCategoryIds: Set<String>,
        format: (Int) -> String
    ) {
        let hidden = balancesHidden
        let row = { (transaction: Transaction) in
            WidgetTransaction(
                id: transaction.id,
                payeeName: transaction.payeeName,
                categoryName: transaction.categoryId.map(hiddenCategoryIds.contains) == true
                    ? nil : transaction.categoryName,
                amount: hidden ? 0 : transaction.amount,
                formattedAmount: format(transaction.amount),
                date: transaction.date
            )
        }
        // ponytail: reads BudgetStore.transactions, the newest 500-row page
        // across all accounts. A month with more rows than that ranks only
        // its newest 500; a dedicated month query is the upgrade path.
        let newestFirst = { (a: Transaction, b: Transaction) in
            (a.date, a.sortOrder ?? 0) > (b.date, b.sortOrder ?? 0)
        }
        recentTransactions = transactions
            .sorted(by: newestFirst)
            .prefix(12)
            .map(row)
        let offBudgetIds = Set(accounts.filter(\.offBudget).map(\.id))
        let monthKey = Int(month.replacingOccurrences(of: "-", with: ""))
        // Hidden balances pick and order by date: ranking by amount, even
        // under masked amounts, would still reveal which purchases were biggest.
        largestTransactions = transactions
            .filter {
                $0.amount < 0 && $0.date / 100 == monthKey
                    && $0.transferAcct == nil && !offBudgetIds.contains($0.accountId)
            }
            .sorted(by: hidden ? newestFirst : { ($0.amount, -$0.date) < ($1.amount, -$1.date) })
            .prefix(12)
            .map(row)
    }

    /// Spending is compared as a positive amount (-spent). This month to date
    /// against last month through the same day (BudgetStore.monthToDateSpending),
    /// summed across categories. Not totalSpent: that counts the whole month,
    /// so a transaction dated later this month would have no match last month.
    private mutating func addMonthComparison(_ spending: MonthToDateSpending, format: (Int) -> String) {
        let spentLastMonthToDate = spending.lastMonth.values.reduce(0, +)
        let lastSpending = -spentLastMonthToDate
        let thisSpending = -spending.thisMonth.values.reduce(0, +)
        let difference = thisSpending - lastSpending
        if balancesHidden {
            // format masks every amount when hidden, so format(0) is the mask
            // text without reaching for BudgetStore's main-actor constant.
            totalSpentLastMonth = 0
            spendingDifference = 0
            spendingPercentChange = 0
            formattedSpendingPercentChange = format(0)
        } else {
            totalSpentLastMonth = spentLastMonthToDate
            spendingDifference = difference
            spendingPercentChange = lastSpending > 0 ? Double(difference) / Double(lastSpending) : nil
            formattedSpendingPercentChange = spendingPercentChange?.formatted(
                .percent.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false))
            )
        }
        formattedTotalSpendingToDate = format(thisSpending)
        formattedTotalSpendingLastMonth = format(lastSpending)
        formattedSpendingDifference = format(difference)
    }

    /// Only for the calendar month `now` falls in; a stale month has no
    /// meaningful "today". Integer division rounds both rates down.
    private mutating func addDailyRates(_ budgetMonth: BudgetMonth, now: Date, format: (Int) -> String) {
        guard isForMonth(containing: now),
              let daysInMonth = Calendar.current.range(of: .day, in: .month, for: now)?.count
        else { return }
        let elapsed = Calendar.current.component(.day, from: now)
        let remaining = daysInMonth - elapsed + 1
        daysElapsed = elapsed
        daysRemaining = remaining
        let average = max(-budgetMonth.totalSpent, 0) / elapsed
        let safe = budgetMonth.totalBudgeted > 0
            ? max(budgetMonth.totalBudgeted + budgetMonth.totalSpent, 0) / remaining
            : nil
        if balancesHidden {
            averageSpendPerDay = 0
            safeDailyRate = 0
        } else {
            averageSpendPerDay = average
            safeDailyRate = safe
        }
        formattedAverageSpendPerDay = format(average)
        formattedSafeDailyRate = balancesHidden ? format(0) : safe.map(format)
        // From the unrounded spend, so the projection doesn't multiply the
        // average's rounding by the month's length.
        formattedProjectedSpending = format(max(-budgetMonth.totalSpent, 0) * daysInMonth / elapsed)
        formattedAverageSpendPerWeek = format(average * 7)
        formattedSafeWeeklyRate = balancesHidden ? format(0) : safe.map { format($0 * 7) }
    }

    /// Extracts the next upcoming bills from schedules. Keeps it simple:
    /// non-completed, non-paid schedules for open accounts with a nextDate,
    /// sorted by date, capped at 12 so Extra Large Portrait can fill its rows.
    private static func buildUpcomingBills(
        schedules: [ScheduleSummary],
        statuses: [String: ScheduleStatus],
        activeAccountIds: Set<String>,
        payeeMap: [String: String],
        format: (Int) -> String
    ) -> [WidgetBillItem] {
        schedules
            .filter { schedule in
                guard !schedule.completed,
                      statuses[schedule.id] != .paid,
                      let accountId = schedule.accountId,
                      activeAccountIds.contains(accountId)
                else { return false }
                return true
            }
            .compactMap { schedule in schedule.nextDate.map { (schedule, $0) } }
            .sorted { $0.1 < $1.1 }
            .prefix(12)
            .map { schedule, date in
                let title = schedule.name.flatMap { $0.isEmpty ? nil : $0 }
                    ?? schedule.payeeId.flatMap { payeeMap[$0] }
                    ?? String(localized: "Scheduled")
                let status: WidgetBillItem.Status = switch statuses[schedule.id] {
                case .missed: .overdue
                case .due: .due
                default: .upcoming
                }
                return WidgetBillItem(
                    id: schedule.id,
                    title: title,
                    amount: schedule.postAmount,
                    formattedAmount: format(abs(schedule.postAmount)),
                    dueDay: date.day,
                    dueMonth: date.month,
                    dueYear: date.year,
                    status: status
                )
            }
    }
}
