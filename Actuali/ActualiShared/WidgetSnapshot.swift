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
    /// "overdue", "due", "upcoming"
    let status: String
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
    var totalIncome: Int?
    var formattedTotalIncome: String?

    // MARK: - Bills

    /// Next upcoming bills, sorted by due date. Capped at 8 to keep the
    /// snapshot small.
    var upcomingBills: [WidgetBillItem]?

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
