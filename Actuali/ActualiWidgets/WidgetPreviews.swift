import SwiftUI
import WidgetKit

// Preview-only sample entries and previews for every widget, kept out of the
// widget files. The gallery and placeholders use each entry's `sample`.

// MARK: - CategoryBalance

private extension CategoryBalanceEntry {
    /// Preview-only: 12 rows so Large (8) and Extra Large Portrait (12) are
    /// filled to their provider limits, with one overspent category.
    static func previewSample(count: Int, balancesHidden: Bool = false) -> CategoryBalanceEntry {
        let rows: [(String, Int)] = [
            ("Groceries", 34218), ("Dining Out", 12350), ("Rent", 0), ("Utilities", 8742),
            ("Fun Money", -4275), ("Transport", 6000), ("Health & Fitness", 2599),
            ("Subscriptions", 1497), ("Clothing", 15000), ("Gifts & Donations", 7525),
            ("Home Maintenance", 22010), ("Emergency Fund", 450_000),
        ]
        let format = FloatingPointFormatStyle<Double>.Currency(code: "USD").locale(Locale(identifier: "en_US"))
        return CategoryBalanceEntry(
            date: .now.addingTimeInterval(-300),
            balancesHidden: balancesHidden,
            categories: rows.prefix(count).enumerated().map { index, row in
                WidgetCategoryBalance(
                    id: "preview-\(index)",
                    name: row.0,
                    available: row.1,
                    formattedAvailable: balancesHidden ? "\u{2022}\u{2022}\u{2022}\u{2022}" : (Double(row.1) / 100).formatted(format)
                )
            },
            hasSnapshot: true
        )
    }
}

#Preview("Small", as: .systemSmall) {
    CategoryBalanceWidget()
} timeline: {
    CategoryBalanceEntry.previewSample(count: 1)
    CategoryBalanceEntry.previewSample(count: 1, balancesHidden: true)
    CategoryBalanceEntry(date: .now, balancesHidden: false, categories: [], hasSnapshot: true)
    CategoryBalanceEntry(date: .now, balancesHidden: false, categories: [], hasSnapshot: false)
}

#Preview("Medium", as: .systemMedium) {
    CategoryBalanceWidget()
} timeline: {
    CategoryBalanceEntry.previewSample(count: 4)
    CategoryBalanceEntry.previewSample(count: 4, balancesHidden: true)
}

#Preview("Large", as: .systemLarge) {
    CategoryBalanceWidget()
} timeline: {
    CategoryBalanceEntry.previewSample(count: 8)
    CategoryBalanceEntry.previewSample(count: 8, balancesHidden: true)
}

@available(iOS 27.0, *)
#Preview("Extra Large Portrait", as: .systemExtraLargePortrait) {
    CategoryBalanceWidget()
} timeline: {
    CategoryBalanceEntry.previewSample(count: 12)
    CategoryBalanceEntry.previewSample(count: 12, balancesHidden: true)
}

// MARK: - AccountBalance

private extension AccountBalanceEntry {
    /// Preview-only: 12 rows so Large (8) and Extra Large Portrait (12) are
    /// filled to their provider limits, with negative credit and debt balances.
    static func previewSample(count: Int, balancesHidden: Bool = false) -> AccountBalanceEntry {
        let rows: [(String, String, Int)] = [
            ("Everyday Checking", "checking", 245_300), ("High-Yield Savings", "savings", 1_500_000),
            ("Rewards Credit Card", "credit", -42150), ("Brokerage", "investment", 3_200_000),
            ("Joint Checking", "checking", 98750), ("Holiday Savings", "savings", 120_000),
            ("Travel Card", "credit", -8999), ("Home Mortgage", "mortgage", -32_500_000),
            ("Car Loan", "debt", -1_250_000), ("Retirement", "investment", 8_450_000),
            ("Cash Wallet", "other", 6500), ("Emergency Fund", "savings", 450_000),
        ]
        let format = FloatingPointFormatStyle<Double>.Currency(code: "USD").locale(Locale(identifier: "en_US"))
        return AccountBalanceEntry(
            date: .now.addingTimeInterval(-300),
            balancesHidden: balancesHidden,
            accounts: rows.prefix(count).enumerated().map { index, row in
                WidgetAccountBalance(
                    id: "preview-\(index)",
                    name: row.0,
                    balance: row.2,
                    formattedBalance: balancesHidden ? "\u{2022}\u{2022}\u{2022}\u{2022}" : (Double(row.2) / 100).formatted(format),
                    type: row.1,
                    offBudget: false
                )
            },
            hasSnapshot: true
        )
    }
}

#Preview("Small", as: .systemSmall) {
    AccountBalanceWidget()
} timeline: {
    AccountBalanceEntry.previewSample(count: 1)
    AccountBalanceEntry.previewSample(count: 1, balancesHidden: true)
    AccountBalanceEntry(date: .now, balancesHidden: false, accounts: [], hasSnapshot: true)
    AccountBalanceEntry(date: .now, balancesHidden: false, accounts: [], hasSnapshot: false)
}

#Preview("Medium", as: .systemMedium) {
    AccountBalanceWidget()
} timeline: {
    AccountBalanceEntry.previewSample(count: 4)
    AccountBalanceEntry.previewSample(count: 4, balancesHidden: true)
}

#Preview("Large", as: .systemLarge) {
    AccountBalanceWidget()
} timeline: {
    AccountBalanceEntry.previewSample(count: 8)
    AccountBalanceEntry.previewSample(count: 8, balancesHidden: true)
}

@available(iOS 27.0, *)
#Preview("Extra Large Portrait", as: .systemExtraLargePortrait) {
    AccountBalanceWidget()
} timeline: {
    AccountBalanceEntry.previewSample(count: 12)
    AccountBalanceEntry.previewSample(count: 12, balancesHidden: true)
}

// MARK: - NetWorth

private extension NetWorthEntry {
    /// Preview-only: 10 rows so Large (6) and Extra Large Portrait (10) are
    /// filled to their provider limits, with negative credit and debt balances.
    static func previewSample(count: Int, balancesHidden: Bool = false) -> NetWorthEntry {
        let rows: [(String, Int, String)] = [
            ("Everyday Checking", 245_300, "checking"), ("High-Yield Savings", 1_500_000, "savings"),
            ("Rewards Credit Card", -42150, "credit"), ("Joint Checking", 98750, "checking"),
            ("Holiday Savings", 120_000, "savings"), ("Travel Card", -8999, "credit"),
            ("Home Mortgage", -32_500_000, "mortgage"), ("Car Loan", -1_250_000, "debt"),
            ("Cash Wallet", 6500, "other"), ("Emergency Fund", 450_000, "savings"),
        ]
        let format = FloatingPointFormatStyle<Double>.Currency(code: "USD").locale(Locale(identifier: "en_US"))
        let masked = "\u{2022}\u{2022}\u{2022}\u{2022}"
        let shown = rows.prefix(count)
        let total = shown.reduce(0) { $0 + $1.1 }
        return NetWorthEntry(
            date: .now.addingTimeInterval(-300),
            balancesHidden: balancesHidden,
            netWorth: total,
            formattedNetWorth: balancesHidden ? masked : (Double(total) / 100).formatted(format),
            accounts: shown.enumerated().map { index, row in
                WidgetAccountBalance(
                    id: "preview-\(index)",
                    name: row.0,
                    balance: row.1,
                    formattedBalance: balancesHidden ? masked : (Double(row.1) / 100).formatted(format),
                    type: row.2,
                    offBudget: false
                )
            },
            hasSnapshot: true
        )
    }
}

#Preview("Small", as: .systemSmall) {
    NetWorthWidget()
} timeline: {
    NetWorthEntry.previewSample(count: 3)
    NetWorthEntry.previewSample(count: 3, balancesHidden: true)
    NetWorthEntry(date: .now, balancesHidden: false, netWorth: nil, formattedNetWorth: nil, accounts: [], hasSnapshot: false)
}

#Preview("Medium", as: .systemMedium) {
    NetWorthWidget()
} timeline: {
    NetWorthEntry.previewSample(count: 3)
    NetWorthEntry.previewSample(count: 3, balancesHidden: true)
    // Every account off-budget: a total, but no rows under it.
    NetWorthEntry(date: .now, balancesHidden: false, netWorth: 900_000, formattedNetWorth: "$9,000.00", accounts: [], hasSnapshot: true)
    NetWorthEntry(date: .now, balancesHidden: false, netWorth: nil, formattedNetWorth: nil, accounts: [], hasSnapshot: false)
}

#Preview("Large", as: .systemLarge) {
    NetWorthWidget()
} timeline: {
    NetWorthEntry.previewSample(count: 6)
    NetWorthEntry.previewSample(count: 6, balancesHidden: true)
}

@available(iOS 27.0, *)
#Preview("Extra Large Portrait", as: .systemExtraLargePortrait) {
    NetWorthWidget()
} timeline: {
    NetWorthEntry.previewSample(count: 10)
    NetWorthEntry.previewSample(count: 10, balancesHidden: true)
}

// MARK: - ToBeBudgeted

private extension ToBeBudgetedEntry {
    /// Preview-only: enough unbudgeted rows to fill Large (5) and Extra Large
    /// Portrait (8), with one overspent category.
    static func previewSample(count: Int, balancesHidden: Bool = false, tracking: Bool = false) -> ToBeBudgetedEntry {
        let rows: [(String, Int)] = [
            ("Gifts", 0), ("Home Maintenance", 12500), ("Clothing", -2350), ("Subscriptions", 0),
            ("Charitable Giving", 4000), ("Pet Supplies", 0), ("Vacation Fund", 60000), ("Hobbies", 1500),
        ]
        let format = FloatingPointFormatStyle<Double>.Currency(code: "USD").locale(Locale(identifier: "en_US"))
        let masked = "\u{2022}\u{2022}\u{2022}\u{2022}"
        func shown(_ cents: Int) -> String {
            balancesHidden ? masked : (Double(cents) / 100).formatted(format)
        }
        return ToBeBudgetedEntry(
            date: .now.addingTimeInterval(-300),
            balancesHidden: balancesHidden,
            toBudget: tracking ? nil : 52340,
            formattedToBudget: tracking ? nil : shown(52340),
            formattedTotalBudgeted: shown(320_000),
            formattedTotalSpending: shown(184_200),
            unbudgeted: rows.prefix(count).enumerated().map { index, row in
                WidgetCategoryBalance(
                    id: "preview-\(index)", name: row.0, available: row.1,
                    formattedAvailable: shown(row.1), budgeted: 0
                )
            },
            hasSnapshot: true,
            isTrackingBudget: tracking
        )
    }
}

#Preview("Small", as: .systemSmall) {
    ToBeBudgetedWidget()
} timeline: {
    ToBeBudgetedEntry.previewSample(count: 0)
    ToBeBudgetedEntry.previewSample(count: 0, balancesHidden: true)
    ToBeBudgetedEntry.previewSample(count: 0, tracking: true)
    ToBeBudgetedEntry(
        date: .now, balancesHidden: false, toBudget: nil, formattedToBudget: nil, formattedTotalBudgeted: nil,
        formattedTotalSpending: nil, unbudgeted: [], hasSnapshot: false, isTrackingBudget: false
    )
}

#Preview("Medium", as: .systemMedium) {
    ToBeBudgetedWidget()
} timeline: {
    ToBeBudgetedEntry.previewSample(count: 0)
    ToBeBudgetedEntry.previewSample(count: 0, balancesHidden: true)
    ToBeBudgetedEntry.previewSample(count: 0, tracking: true)
}

#Preview("Large", as: .systemLarge) {
    ToBeBudgetedWidget()
} timeline: {
    ToBeBudgetedEntry.previewSample(count: 5)
    ToBeBudgetedEntry.previewSample(count: 5, balancesHidden: true)
    ToBeBudgetedEntry.previewSample(count: 0)
}

@available(iOS 27.0, *)
#Preview("Extra Large Portrait", as: .systemExtraLargePortrait) {
    ToBeBudgetedWidget()
} timeline: {
    ToBeBudgetedEntry.previewSample(count: 8)
    ToBeBudgetedEntry.previewSample(count: 8, balancesHidden: true)
}

// MARK: - UpcomingBills

private extension UpcomingBillsEntry {
    /// Preview-only: 12 bills so Medium (3), Large (6), and Extra Large
    /// Portrait (12) are filled to their provider limits, with overdue, due, and income rows.
    static func previewSample(count: Int, balancesHidden: Bool = false) -> UpcomingBillsEntry {
        let rows: [(String, Int, Int, Int, WidgetBillItem.Status)] = [
            ("Car Insurance", -14250, 11, 22, .overdue), ("Electric Utility", -8500, 11, 25, .due),
            ("Internet", -6000, 11, 27, .upcoming), ("Paycheck", 245_000, 11, 28, .upcoming),
            ("Rent", -120_000, 12, 1, .upcoming), ("Streaming Subscription Bundle", -2299, 12, 2, .upcoming),
            ("Phone", -4500, 12, 4, .upcoming), ("Gym Membership", -3999, 12, 5, .upcoming),
            ("Water & Sewer", -5120, 12, 8, .upcoming), ("Student Loan", -32000, 12, 10, .upcoming),
            ("Credit Card Payment", -50000, 12, 12, .upcoming), ("Cloud Storage", -299, 12, 14, .upcoming),
        ]
        let format = FloatingPointFormatStyle<Double>.Currency(code: "USD").locale(Locale(identifier: "en_US"))
        return UpcomingBillsEntry(
            date: .now.addingTimeInterval(-300),
            balancesHidden: balancesHidden,
            bills: rows.prefix(count).enumerated().map { index, row in
                WidgetBillItem(
                    id: "preview-\(index)",
                    title: row.0,
                    amount: row.1,
                    formattedAmount: balancesHidden ? "\u{2022}\u{2022}\u{2022}\u{2022}" : (Double(abs(row.1)) / 100).formatted(format),
                    dueDay: row.3,
                    dueMonth: row.2,
                    dueYear: 2026,
                    status: row.4
                )
            },
            hasSnapshot: true
        )
    }
}

#Preview("Small", as: .systemSmall) {
    UpcomingBillsWidget()
} timeline: {
    UpcomingBillsEntry.previewSample(count: 1)
    UpcomingBillsEntry.previewSample(count: 1, balancesHidden: true)
    UpcomingBillsEntry(date: .now, balancesHidden: false, bills: [], hasSnapshot: true)
    UpcomingBillsEntry(date: .now, balancesHidden: false, bills: [], hasSnapshot: false)
}

#Preview("Medium", as: .systemMedium) {
    UpcomingBillsWidget()
} timeline: {
    UpcomingBillsEntry.previewSample(count: 3)
    UpcomingBillsEntry.previewSample(count: 3, balancesHidden: true)
}

#Preview("Large", as: .systemLarge) {
    UpcomingBillsWidget()
} timeline: {
    UpcomingBillsEntry.previewSample(count: 6)
    UpcomingBillsEntry.previewSample(count: 6, balancesHidden: true)
}

@available(iOS 27.0, *)
#Preview("Extra Large Portrait", as: .systemExtraLargePortrait) {
    UpcomingBillsWidget()
} timeline: {
    UpcomingBillsEntry.previewSample(count: 12)
    UpcomingBillsEntry.previewSample(count: 12, balancesHidden: true)
}

// MARK: - SpendingSummary

private extension SpendingSummaryEntry {
    /// Preview-only: enough rows to fill Large (5) and Extra Large Portrait
    /// (8), with one overspent category; `overbudget` pushes spending past
    /// the budget to show the red state.
    static func previewSample(count: Int, balancesHidden: Bool = false, overbudget: Bool = false) -> SpendingSummaryEntry {
        let rows: [(String, Int)] = [
            ("Groceries", 34218), ("Dining Out", 12350), ("Rent", 0), ("Utilities", 8742),
            ("Fun Money", -4275), ("Transport", 6000), ("Health & Fitness", 2599), ("Subscriptions", 1497),
        ]
        let format = FloatingPointFormatStyle<Double>.Currency(code: "USD").locale(Locale(identifier: "en_US"))
        func shown(_ cents: Int) -> String {
            balancesHidden ? "\u{2022}\u{2022}\u{2022}\u{2022}" : (Double(cents) / 100).formatted(format)
        }
        let spent = overbudget ? -352_475 : -184_200
        var snapshot = WidgetSnapshot(month: "", generatedAt: .now, balancesHidden: balancesHidden, categories: [])
        snapshot.totalSpent = spent
        snapshot.totalBudgeted = 320_000
        return SpendingSummaryEntry(
            date: .now.addingTimeInterval(-300),
            balancesHidden: balancesHidden,
            spentFraction: snapshot.spentFraction,
            isOverbudget: snapshot.isOverbudget,
            formattedTotalSpent: shown(spent),
            formattedTotalBudgeted: shown(320_000),
            formattedTotalIncome: shown(450_000),
            categories: rows.prefix(count).enumerated().map { index, row in
                WidgetCategoryBalance(id: "preview-\(index)", name: row.0, available: row.1, formattedAvailable: shown(row.1))
            },
            hasSnapshot: true
        )
    }
}

#Preview("Small", as: .systemSmall) {
    SpendingSummaryWidget()
} timeline: {
    SpendingSummaryEntry.previewSample(count: 0)
    SpendingSummaryEntry.previewSample(count: 0, overbudget: true)
    SpendingSummaryEntry.previewSample(count: 0, balancesHidden: true)
    SpendingSummaryEntry(
        date: .now, balancesHidden: false, spentFraction: 0, isOverbudget: false, formattedTotalSpent: nil,
        formattedTotalBudgeted: nil, formattedTotalIncome: nil, categories: [], hasSnapshot: false
    )
}

#Preview("Medium", as: .systemMedium) {
    SpendingSummaryWidget()
} timeline: {
    SpendingSummaryEntry.previewSample(count: 0)
    SpendingSummaryEntry.previewSample(count: 0, overbudget: true)
    SpendingSummaryEntry.previewSample(count: 0, balancesHidden: true)
}

#Preview("Large", as: .systemLarge) {
    SpendingSummaryWidget()
} timeline: {
    SpendingSummaryEntry.previewSample(count: 5)
    SpendingSummaryEntry.previewSample(count: 5, overbudget: true)
    SpendingSummaryEntry.previewSample(count: 5, balancesHidden: true)
    SpendingSummaryEntry.previewSample(count: 0)
}

@available(iOS 27.0, *)
#Preview("Extra Large Portrait", as: .systemExtraLargePortrait) {
    SpendingSummaryWidget()
} timeline: {
    SpendingSummaryEntry.previewSample(count: 8)
    SpendingSummaryEntry.previewSample(count: 8, overbudget: true)
    SpendingSummaryEntry.previewSample(count: 8, balancesHidden: true)
}
