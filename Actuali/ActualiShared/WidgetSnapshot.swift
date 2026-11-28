import Foundation

/// One category's remaining balance as the widget shows it. The amount is
/// pre-formatted by the app because the currency settings live in the app's
/// standard UserDefaults, out of the widget process's reach.
struct WidgetCategoryBalance: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    /// In cents; carried alongside the formatted string so the widget can
    /// color overspent categories without parsing the display text.
    let available: Int
    let formattedAvailable: String
    /// Cents assigned this month; 0 marks the category as unbudgeted for the
    /// To Be Budgeted widget. nil only in snapshots written before this field
    /// existed, and counts as unknown rather than unbudgeted.
    var budgeted: Int?
    /// Net activity this month in cents (negative = spending), zeroed when
    /// balances are hidden so rankedCategories can't order by it. nil in
    /// snapshots written before it existed.
    var spent: Int?
    /// Spending as a positive amount; a net inflow shows negative.
    var formattedSpent: String?
    var formattedBudgeted: String?
    /// This month's spending minus last month's to the same day, in cents
    /// (positive = spending more), for the Spending vs Last Month movers.
    /// Zeroed when hidden, like spent; nil without last month's data.
    var spendingDifference: Int?
    var formattedSpendingDifference: String?

    var isOverspent: Bool {
        available < 0
    }
}

/// One account's balance as the widget shows it.
struct WidgetAccountBalance: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let balance: Int // cents
    let formattedBalance: String
    let type: String // AccountType raw value
    let offBudget: Bool
}

/// One transaction row for the widget. Amount is 0 when balances are
/// hidden, so neither the size nor an income sign leaks past the mask, and
/// categoryName is nil for a hidden category.
struct WidgetTransaction: Codable, Equatable, Identifiable {
    let id: String
    let payeeName: String?
    let categoryName: String?
    let amount: Int // cents (negative = outflow)
    let formattedAmount: String
    let date: Int // YYYYMMDD
}

/// One upcoming bill for the widget.
struct WidgetBillItem: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let amount: Int // cents (negative = outflow)
    let formattedAmount: String
    /// Day/month/year stored separately so the widget can format the date
    /// without needing Calendar on the app side.
    let dueDay: Int
    let dueMonth: Int
    let dueYear: Int
    let status: Status

    enum Status: String, Codable {
        case overdue, due, upcoming
    }
}

/// Everything the widget needs to render, written by the app after each data
/// refresh and read by the widget extension through the app group container.
/// App and widget ship as one bundle, so both always agree on this format;
/// a failed decode (nil) already covers any future format change.
struct WidgetSnapshot: Codable, Equatable {
    /// The budget month these balances describe ("2026-08"). The widget
    /// refuses to show a past month as current — see isForMonth(containing:).
    let month: String
    var generatedAt: Date
    /// Mirrors the app's hide-balances privacy setting. The formatted amounts
    /// arrive already masked; the widget additionally mutes overspent
    /// coloring so the sign doesn't leak through the mask.
    let balancesHidden: Bool
    let categories: [WidgetCategoryBalance]

    // MARK: - Accounts

    /// All non-closed accounts, sorted by sort order.
    var accounts: [WidgetAccountBalance]?
    /// Sum of all non-closed account balances (cents).
    var netWorth: Int?
    var formattedNetWorth: String?

    // MARK: - Budget

    /// Unallocated funds ("To Budget"). nil for tracking budgets.
    var toBudget: Int?
    var formattedToBudget: String?
    var totalBudgeted: Int?
    var formattedTotalBudgeted: String?
    /// Negative (money out), net of inflows.
    var totalSpent: Int?
    var formattedTotalSpent: String?
    /// totalSpent as a positive amount, matching the category rows'
    /// formattedSpent, for headers that sit above those rows.
    var formattedTotalSpending: String?
    var formattedTotalIncome: String?

    // MARK: - Bills

    /// Next upcoming bills, sorted by due date. Capped at 12 (the Extra
    /// Large Portrait row count) to keep the snapshot small.
    var upcomingBills: [WidgetBillItem]?

    // MARK: - Transactions

    /// Newest first across all accounts, capped at 12.
    var recentTransactions: [WidgetTransaction]?
    /// This month's on-budget outflows, largest first, capped at 12; newest
    /// first instead when balances are hidden, so the list can't rank by size.
    /// Income, transfers and off-budget accounts are excluded.
    var largestTransactions: [WidgetTransaction]?

    // MARK: - Month comparison

    /// This month's spending from the 1st through today, as a positive
    /// amount. Unlike formattedTotalSpending it leaves out transactions dated
    /// later this month, which have no match on last month's side.
    var formattedTotalSpendingToDate: String?
    /// Last month's net spending from its 1st through today's day number,
    /// signed like totalSpent (negative = spending), so month to date
    /// compares with the same point last month. nil when last month had no
    /// spending transactions in that window.
    var totalSpentLastMonth: Int?
    /// totalSpentLastMonth as a positive amount, like formattedTotalSpending.
    var formattedTotalSpendingLastMonth: String?
    /// This month's spending minus last month's, in cents; positive means
    /// spending more this month.
    var spendingDifference: Int?
    var formattedSpendingDifference: String?
    /// spendingDifference over last month's spending (0.5 = 50% more). nil
    /// when last month had no spending to divide by.
    var spendingPercentChange: Double?
    var formattedSpendingPercentChange: String?

    // MARK: - Daily rates

    /// Days of the month so far and still to come; today counts in both, so
    /// daysRemaining is 1 on the last day, never 0.
    var daysElapsed: Int?
    var daysRemaining: Int?
    var averageSpendPerDay: Int?
    var formattedAverageSpendPerDay: String?
    /// Remaining budget (floored at 0) over daysRemaining. nil with nothing
    /// budgeted.
    var safeDailyRate: Int?
    var formattedSafeDailyRate: String?
    /// The Daily Burn Rate widget's Large and Extra Large Portrait extras:
    /// the month's spending at the current pace, and both rates over a week.
    /// Formatted only, as the widget shows them and colours nothing by them.
    var formattedProjectedSpending: String?
    var formattedAverageSpendPerWeek: String?
    /// nil with nothing budgeted, like formattedSafeDailyRate.
    var formattedSafeWeeklyRate: String?

    /// Same format as BudgetStore's yearMonthFormatter — the two must agree
    /// or the widget would flag every snapshot as stale.
    private static let yearMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    /// Whether these balances describe the month containing `date`. False
    /// once the calendar rolls over without the app running — the widget
    /// shows its empty state then, rather than passing off last month's
    /// balances as current.
    func isForMonth(containing date: Date) -> Bool {
        month == Self.yearMonthFormatter.string(from: date)
    }

    /// The user's chosen categories in their chosen order, capped at what the
    /// widget family can display. An empty selection falls back to the
    /// budget's first categories so a freshly added widget isn't blank.
    func categories(matching ids: [String], limit: Int) -> [WidgetCategoryBalance] {
        guard !ids.isEmpty else { return Array(categories.prefix(limit)) }
        let byId = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Array(ids.compactMap { byId[$0] }.prefix(limit))
    }

    /// Categories with nothing budgeted this month, in budget order, capped
    /// at `limit`. Balance plays no part: carryover can leave money in an
    /// unbudgeted category. Every category when hidden: budgeted keeps its
    /// raw cents under the mask, so filtering on it would reveal which
    /// categories have nothing assigned.
    func unbudgetedCategories(limit: Int) -> [WidgetCategoryBalance] {
        Array(categories.filter { balancesHidden || $0.budgeted == 0 }.prefix(limit))
    }

    /// Share of the month's budget spent, capped at 1 for the Monthly
    /// Spending progress bar. 0 when hidden — the raw cents ride along under
    /// the mask, and the fill would leak the ratio — or with nothing to
    /// measure against.
    var spentFraction: Double {
        guard !balancesHidden, let totalSpent, let totalBudgeted, totalBudgeted > 0 else { return 0 }
        return min(Double(abs(totalSpent)) / Double(totalBudgeted), 1.0)
    }

    /// False when hidden, so the red tint can't leak through the mask.
    var isOverbudget: Bool {
        guard !balancesHidden, let totalSpent, let totalBudgeted, totalBudgeted > 0 else { return false }
        return abs(totalSpent) > totalBudgeted
    }

    /// Share of the month gone, today included (1 on the last day). Days
    /// carry no amount, so it stays when hidden. nil without the day counts.
    var monthProgress: Double? {
        guard let daysElapsed, let daysRemaining else { return nil }
        return Double(daysElapsed) / Double(daysElapsed + daysRemaining - 1)
    }

    enum SpendingTrend: Equatable {
        case more, less, same
    }

    /// Which way spending moved against the same point last month. nil
    /// without last month's data, and when hidden: the zeroed difference
    /// would read as "same", and an arrow or red would leak the direction.
    var spendingTrend: SpendingTrend? {
        trend(spendingDifference)
    }

    /// One mover's direction, nil on the same terms as spendingTrend.
    func spendingTrend(of category: WidgetCategoryBalance) -> SpendingTrend? {
        trend(category.spendingDifference)
    }

    private func trend(_ difference: Int?) -> SpendingTrend? {
        guard !balancesHidden, let difference else { return nil }
        if difference > 0 {
            return .more
        }
        return difference < 0 ? .less : .same
    }

    /// The Spending vs Last Month widget's category movers: the biggest
    /// change either way first, ties in budget order, capped at `limit`.
    /// Unchanged categories drop out, but not when hidden: the difference is
    /// zeroed there, so every category stays in budget order and neither
    /// the ranking nor the filtering reveals which moved. Empty without last
    /// month's data.
    func categoryMovers(limit: Int) -> [WidgetCategoryBalance] {
        let movers = categories.enumerated()
            .compactMap { index, category in category.spendingDifference.map { (change: abs($0), index: index, category: category) } }
            .filter { balancesHidden || $0.change != 0 }
            .sorted { (-$0.change, $0.index) < (-$1.change, $1.index) }
        return Array(movers.prefix(limit).map(\.category))
    }

    /// Every category by spending this month, most spent first. Ties (and
    /// every row when hidden, where spent is 0) keep budget order. Empty for
    /// snapshots written before spent existed.
    private var categoriesBySpending: [WidgetCategoryBalance] {
        categories.enumerated()
            .compactMap { index, category in category.spent.map { (spent: $0, index: index, category: category) } }
            .sorted { ($0.spent, $0.index) < ($1.spent, $1.index) }
            .map(\.category)
    }

    /// categoriesBySpending capped at 12, the most any widget shows.
    var rankedCategories: [WidgetCategoryBalance] {
        Array(categoriesBySpending.prefix(12))
    }

    /// The Top Spending widget's rows, capped at `limit`. Categories with no
    /// spending or a net inflow drop out, so a quiet month shows the empty
    /// state rather than a $0 "top" category. Not when hidden: spent is
    /// zeroed there, and filtering would blank the widget.
    func topSpendingCategories(limit: Int) -> [WidgetCategoryBalance] {
        let spenders = balancesHidden ? rankedCategories : rankedCategories.filter { ($0.spent ?? 0) < 0 }
        return Array(spenders.prefix(limit))
    }

    /// The Overspent Alerts widget's rows, most spent first. Uncapped, so an
    /// overspent category outside the top 12 spenders (say, one overspent by
    /// carryover alone) still shows and Small's count matches the Budget
    /// tab's. When hidden, the first 12 in budget order instead: available
    /// keeps its raw cents under the mask, so filtering on it would reveal
    /// which categories are overspent.
    var overspentCategories: [WidgetCategoryBalance] {
        balancesHidden ? rankedCategories : categoriesBySpending.filter(\.isOverspent)
    }

    /// The next bills by due date, capped at `limit`; empty for snapshots
    /// written before bills existed.
    func nextBills(limit: Int) -> [WidgetBillItem] {
        Array((upcomingBills ?? []).prefix(limit))
    }

    /// The newest transactions, capped at `limit`; empty for snapshots
    /// written before transactions existed.
    func latestTransactions(limit: Int) -> [WidgetTransaction] {
        Array((recentTransactions ?? []).prefix(limit))
    }

    /// This month's biggest purchases, capped at `limit` — newest instead
    /// when hidden (see largestTransactions); empty for snapshots written
    /// before transactions existed.
    func largestTransactions(limit: Int) -> [WidgetTransaction] {
        Array((largestTransactions ?? []).prefix(limit))
    }

    /// The user's chosen accounts in their chosen order, capped at `limit`.
    /// An empty selection falls back to on-budget accounts.
    func accounts(matching ids: [String], limit: Int) -> [WidgetAccountBalance] {
        guard let accounts else { return [] }
        guard !ids.isEmpty else {
            return Array(accounts.filter { !$0.offBudget }.prefix(limit))
        }
        let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Array(ids.compactMap { byId[$0] }.prefix(limit))
    }
}
