import Foundation

/// How many rows each widget lists per home screen family. The one source
/// for both the widget providers (WidgetSupport's rows(for:)) and the tests,
/// so a changed limit can't leave the tests checking an old number. Free of
/// WidgetKit, so the app and test targets compile it unchanged. 0 means the
/// family shows no list.
struct WidgetRowLimits: Equatable {
    let small: Int
    let medium: Int
    let large: Int
    let extraLargePortrait: Int

    static let categoryBalance = WidgetRowLimits(small: 1, medium: 4, large: 8, extraLargePortrait: 12)
    static let accountBalance = WidgetRowLimits(small: 1, medium: 4, large: 8, extraLargePortrait: 12)
    static let netWorth = WidgetRowLimits(small: 0, medium: 3, large: 6, extraLargePortrait: 10)
    static let toBeBudgeted = WidgetRowLimits(small: 0, medium: 0, large: 5, extraLargePortrait: 8)
    static let spendingSummary = WidgetRowLimits(small: 0, medium: 0, large: 5, extraLargePortrait: 8)
    static let upcomingBills = WidgetRowLimits(small: 1, medium: 3, large: 6, extraLargePortrait: 12)
    static let recentTransactions = WidgetRowLimits(small: 3, medium: 4, large: 8, extraLargePortrait: 12)
    static let largestTransactions = WidgetRowLimits(small: 1, medium: 3, large: 5, extraLargePortrait: 8)
    static let topSpending = WidgetRowLimits(small: 1, medium: 3, large: 5, extraLargePortrait: 8)
    /// Small shows the overspent count with the worst category, not a list.
    static let overspentAlerts = WidgetRowLimits(small: 1, medium: 4, large: 8, extraLargePortrait: 12)
    /// Spending vs Last Month's category movers, listed on Large and up.
    static let spendingMovers = WidgetRowLimits(small: 0, medium: 0, large: 1, extraLargePortrait: 4)

    /// The Overview widget's section sizes. It is Extra Large Portrait only,
    /// so each section has one size rather than one per family.
    struct Overview: Equatable {
        let accounts: Int
        let categories: Int
        let transactions: Int
        let bills: Int
    }

    static let overview = Overview(accounts: 3, categories: 4, transactions: 3, bills: 3)
}
