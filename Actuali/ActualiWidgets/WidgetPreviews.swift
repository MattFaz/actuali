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

// MARK: - RecentTransactions

private extension RecentTransactionsEntry {
    /// Preview-only: long payee and category names plus a four-digit income
    /// amount, so truncation always lands on the names. 12 rows so Large (8)
    /// and Extra Large Portrait (12) fill to their provider limits.
    static func previewSample(count: Int, balancesHidden: Bool = false) -> RecentTransactionsEntry {
        let rows: [(String, String, Int, Int)] = [
            ("Corner Café & Bakery", "Dining Out", -1250, 20_261_124),
            ("Fresh Market Grocery", "Groceries", -6342, 20_261_123),
            ("Acme Corporation Payroll", "Income", 245_000, 20_261_121),
            ("City Transit Authority", "Transport", -275, 20_261_120),
            ("Streaming Subscription Bundle", "Subscriptions", -2299, 20_261_118),
            ("Hardware Depot", "Home Maintenance", -8915, 20_261_117),
            ("Neighbourhood Pharmacy", "Health & Fitness", -1840, 20_261_116),
            ("City Power & Light", "Utilities", -11260, 20_261_115),
            ("Bookshop on Main", "Fun Money", -2400, 20_261_114),
            ("Sunday Farmers Market", "Groceries", -3150, 20_261_113),
            ("Refund: Outdoor Gear Co", "Clothing", 4999, 20_261_112),
            ("Petrol Station", "Transport", -6020, 20_261_111),
        ]
        let format = FloatingPointFormatStyle<Double>.Currency(code: "USD").locale(Locale(identifier: "en_US"))
        return RecentTransactionsEntry(
            date: .now.addingTimeInterval(-300),
            balancesHidden: balancesHidden,
            transactions: rows.prefix(count).enumerated().map { index, row in
                WidgetTransaction(
                    id: "preview-\(index)",
                    payeeName: row.0,
                    // Mirrors the snapshot: a hidden category's name is blank under the mask.
                    categoryName: balancesHidden && index == 1 ? nil : row.1,
                    amount: balancesHidden ? 0 : row.2,
                    formattedAmount: balancesHidden ? "\u{2022}\u{2022}\u{2022}\u{2022}" : (Double(row.2) / 100).formatted(format),
                    date: row.3
                )
            },
            formattedMonthTotal: balancesHidden ? "\u{2022}\u{2022}\u{2022}\u{2022}" : "$1,842.00",
            hasSnapshot: true
        )
    }
}

#Preview("Small", as: .systemSmall) {
    RecentTransactionsWidget()
} timeline: {
    RecentTransactionsEntry.previewSample(count: 3)
    RecentTransactionsEntry.previewSample(count: 3, balancesHidden: true)
    RecentTransactionsEntry(date: .now, balancesHidden: false, transactions: [], formattedMonthTotal: nil, hasSnapshot: true)
}

#Preview("Medium", as: .systemMedium) {
    RecentTransactionsWidget()
} timeline: {
    RecentTransactionsEntry.previewSample(count: 5)
    RecentTransactionsEntry.previewSample(count: 5, balancesHidden: true)
}

#Preview("Large", as: .systemLarge) {
    RecentTransactionsWidget()
} timeline: {
    RecentTransactionsEntry.previewSample(count: 8)
    RecentTransactionsEntry.previewSample(count: 8, balancesHidden: true)
    RecentTransactionsEntry.previewSample(count: 2)
    RecentTransactionsEntry(date: .now, balancesHidden: false, transactions: [], formattedMonthTotal: nil, hasSnapshot: false)
}

@available(iOS 27.0, *)
#Preview("Extra Large Portrait", as: .systemExtraLargePortrait) {
    RecentTransactionsWidget()
} timeline: {
    RecentTransactionsEntry.previewSample(count: 12)
    RecentTransactionsEntry.previewSample(count: 12, balancesHidden: true)
}

// MARK: - TopSpending

private extension TopSpendingEntry {
    /// Preview-only: a long category name, a four-digit amount, and one
    /// overspent category, so truncation lands on the name. 8 rows so Large
    /// (5) and Extra Large Portrait (8) fill to their provider limits.
    static func previewSample(count: Int, balancesHidden: Bool = false) -> TopSpendingEntry {
        let rows: [(String, Int, Int)] = [
            ("Groceries & Household Supplies", 60000, -123_456),
            ("Dining Out", 20000, -21550),
            ("Transport", 10000, -6000),
            ("Utilities", 15000, -11260),
            ("Subscriptions & Streaming", 5000, -4597),
            ("Health & Fitness", 8000, -3840),
            ("Home Maintenance", 10000, -2915),
            ("Fun Money", 5000, -2400),
        ]
        let format = FloatingPointFormatStyle<Double>.Currency(code: "USD").locale(Locale(identifier: "en_US"))
        let mask = "\u{2022}\u{2022}\u{2022}\u{2022}"
        let text: (Int) -> String = { balancesHidden ? mask : (Double($0) / 100).formatted(format) }
        return TopSpendingEntry(
            date: .now.addingTimeInterval(-300),
            balancesHidden: balancesHidden,
            categories: rows.prefix(count).enumerated().map { index, row in
                WidgetCategoryBalance(
                    id: "preview-\(index)",
                    name: row.0,
                    available: row.1 + row.2,
                    formattedAvailable: text(row.1 + row.2),
                    budgeted: row.1,
                    spent: balancesHidden ? 0 : row.2,
                    formattedSpent: text(-row.2),
                    formattedBudgeted: text(row.1)
                )
            },
            formattedTotalSpending: balancesHidden ? mask : "$1,842.00",
            hasSnapshot: true
        )
    }
}

#Preview("Small", as: .systemSmall) {
    TopSpendingWidget()
} timeline: {
    TopSpendingEntry.previewSample(count: 1)
    TopSpendingEntry(date: .now, balancesHidden: false, categories: [TopSpendingEntry.sample.categories[1]], formattedTotalSpending: nil, hasSnapshot: true)
    TopSpendingEntry.previewSample(count: 1, balancesHidden: true)
    TopSpendingEntry(date: .now, balancesHidden: false, categories: [], formattedTotalSpending: nil, hasSnapshot: true)
}

#Preview("Medium", as: .systemMedium) {
    TopSpendingWidget()
} timeline: {
    TopSpendingEntry.previewSample(count: 3)
    TopSpendingEntry.previewSample(count: 3, balancesHidden: true)
    TopSpendingEntry(date: .now, balancesHidden: false, categories: [], formattedTotalSpending: nil, hasSnapshot: false)
}

#Preview("Large", as: .systemLarge) {
    TopSpendingWidget()
} timeline: {
    TopSpendingEntry.previewSample(count: 5)
    TopSpendingEntry.previewSample(count: 5, balancesHidden: true)
    TopSpendingEntry.previewSample(count: 2)
    TopSpendingEntry(date: .now, balancesHidden: false, categories: [], formattedTotalSpending: nil, hasSnapshot: true)
}

@available(iOS 27.0, *)
#Preview("Extra Large Portrait", as: .systemExtraLargePortrait) {
    TopSpendingWidget()
} timeline: {
    TopSpendingEntry.previewSample(count: 8)
    TopSpendingEntry.previewSample(count: 8, balancesHidden: true)
}

// MARK: - DailyBurnRate

private extension DailyBurnRateEntry {
    /// Preview-only: four-digit amounts so the scale-down shows up.
    static func previewSample(overbudget: Bool = false, balancesHidden: Bool = false) -> DailyBurnRateEntry {
        let mask = "\u{2022}\u{2022}\u{2022}\u{2022}"
        return DailyBurnRateEntry(
            date: .now.addingTimeInterval(-300),
            formattedAverageSpendPerDay: balancesHidden ? mask : "$1,234.56",
            formattedSafeDailyRate: balancesHidden ? mask : (overbudget ? "$0.00" : "$987.65"),
            isOverbudget: overbudget && !balancesHidden,
            formattedProjectedSpending: balancesHidden ? mask : "$37,036.80",
            formattedAverageSpendPerWeek: balancesHidden ? mask : "$8,641.92",
            formattedSafeWeeklyRate: balancesHidden ? mask : (overbudget ? "$0.00" : "$6,913.55"),
            daysElapsed: 10,
            daysRemaining: 21,
            monthProgress: 10.0 / 30
        )
    }
}

#Preview("Small", as: .systemSmall) {
    DailyBurnRateWidget()
} timeline: {
    DailyBurnRateEntry.previewSample()
    DailyBurnRateEntry.previewSample(balancesHidden: true)
    DailyBurnRateEntry(date: .now, formattedAverageSpendPerDay: nil, formattedSafeDailyRate: nil, isOverbudget: false)
}

#Preview("Medium", as: .systemMedium) {
    DailyBurnRateWidget()
} timeline: {
    DailyBurnRateEntry.previewSample()
    DailyBurnRateEntry.previewSample(overbudget: true)
    DailyBurnRateEntry.previewSample(balancesHidden: true)
    DailyBurnRateEntry(date: .now, formattedAverageSpendPerDay: "$12.00", formattedSafeDailyRate: nil, isOverbudget: false)
    DailyBurnRateEntry(date: .now, formattedAverageSpendPerDay: nil, formattedSafeDailyRate: nil, isOverbudget: false)
}

#Preview("Large", as: .systemLarge) {
    DailyBurnRateWidget()
} timeline: {
    DailyBurnRateEntry.previewSample()
    DailyBurnRateEntry.previewSample(overbudget: true)
    DailyBurnRateEntry.previewSample(balancesHidden: true)
    DailyBurnRateEntry(date: .now, formattedAverageSpendPerDay: nil, formattedSafeDailyRate: nil, isOverbudget: false)
}

@available(iOS 27.0, *)
#Preview("Extra Large Portrait", as: .systemExtraLargePortrait) {
    DailyBurnRateWidget()
} timeline: {
    DailyBurnRateEntry.previewSample()
    DailyBurnRateEntry.previewSample(overbudget: true)
    DailyBurnRateEntry.previewSample(balancesHidden: true)
    DailyBurnRateEntry(date: .now, formattedAverageSpendPerDay: nil, formattedSafeDailyRate: nil, isOverbudget: false)
}

// MARK: - LargestTransactions

private extension LargestTransactionsEntry {
    /// Preview-only: long payee and category names plus a four-digit amount,
    /// so truncation always lands on the names. Hidden rows arrive newest
    /// first, as the snapshot orders them.
    static func previewSample(count: Int, balancesHidden: Bool = false) -> LargestTransactionsEntry {
        let mask = "\u{2022}\u{2022}\u{2022}\u{2022}"
        let largestFirst: [(String, String, Int, Int)] = [
            ("Riverside Apartments Management", "Rent", -145_000, 20_261_101),
            ("Fresh Market Grocery", "Groceries", -18342, 20_261_118),
            ("City Power & Light Company", "Utilities", -9611, 20_261_109),
            ("Northside Auto Repair", "Car Maintenance", -8450, 20_261_112),
            ("Lumen Internet", "Utilities", -6999, 20_261_105),
            ("Corner Café", "Dining Out", -4215, 20_261_120),
            ("Metro Transit", "Transport", -3500, 20_261_103),
            ("Bookworm Books", "Entertainment", -2899, 20_261_115),
        ]
        let rows = balancesHidden ? largestFirst.sorted { $0.3 > $1.3 } : largestFirst
        let format = FloatingPointFormatStyle<Double>.Currency(code: "USD").locale(Locale(identifier: "en_US"))
        return LargestTransactionsEntry(
            date: .now.addingTimeInterval(-300),
            balancesHidden: balancesHidden,
            transactions: rows.prefix(count).enumerated().map { index, row in
                WidgetTransaction(
                    id: "preview-\(index)",
                    payeeName: row.0,
                    // Mirrors the snapshot: a hidden category's name is blank under the mask.
                    categoryName: balancesHidden && index == 0 ? nil : row.1,
                    amount: balancesHidden ? 0 : row.2,
                    formattedAmount: balancesHidden ? mask : (Double(row.2) / 100).formatted(format),
                    date: row.3
                )
            },
            hasSnapshot: true,
            formattedTotalSpending: balancesHidden ? mask : "$1,842.00"
        )
    }
}

#Preview("Small", as: .systemSmall) {
    LargestTransactionsWidget()
} timeline: {
    LargestTransactionsEntry.previewSample(count: 1)
    LargestTransactionsEntry.previewSample(count: 1, balancesHidden: true)
    LargestTransactionsEntry(date: .now, balancesHidden: false, transactions: [], hasSnapshot: true)
    LargestTransactionsEntry(date: .now, balancesHidden: false, transactions: [], hasSnapshot: false)
}

#Preview("Medium", as: .systemMedium) {
    LargestTransactionsWidget()
} timeline: {
    LargestTransactionsEntry.previewSample(count: 3)
    LargestTransactionsEntry.previewSample(count: 1)
    LargestTransactionsEntry.previewSample(count: 3, balancesHidden: true)
    LargestTransactionsEntry(date: .now, balancesHidden: false, transactions: [], hasSnapshot: true)
}

#Preview("Large", as: .systemLarge) {
    LargestTransactionsWidget()
} timeline: {
    LargestTransactionsEntry.previewSample(count: 5)
    LargestTransactionsEntry.previewSample(count: 2)
    LargestTransactionsEntry.previewSample(count: 5, balancesHidden: true)
    LargestTransactionsEntry(date: .now, balancesHidden: false, transactions: [], hasSnapshot: true)
    LargestTransactionsEntry(date: .now, balancesHidden: false, transactions: [], hasSnapshot: false)
}

@available(iOS 27.0, *)
#Preview("Extra Large Portrait", as: .systemExtraLargePortrait) {
    LargestTransactionsWidget()
} timeline: {
    LargestTransactionsEntry.previewSample(count: 8)
    LargestTransactionsEntry.previewSample(count: 3)
    LargestTransactionsEntry.previewSample(count: 8, balancesHidden: true)
    LargestTransactionsEntry(date: .now, balancesHidden: false, transactions: [], hasSnapshot: true)
}

// MARK: - OverspentAlerts

private extension OverspentAlertsEntry {
    /// Preview-only: a long category name and a four-digit overspend, so
    /// truncation lands on the name. Hidden rows arrive in budget order,
    /// overspent or not, as the snapshot sends them.
    static func previewSample(count: Int, balancesHidden: Bool = false) -> OverspentAlertsEntry {
        let worstFirst: [(String, Int, Int)] = [
            ("Groceries & Household Supplies", 60000, -183_456),
            ("Dining Out", 20000, -21550),
            ("Transport", 10000, -10820),
            ("Gifts", 5000, -5100),
            ("Pets", 3000, -3050),
            ("Clothing", 10000, -12400),
            ("Subscriptions", 2500, -2999),
            ("Coffee", 4000, -4650),
            ("Haircuts", 3500, -4000),
            ("Books", 2000, -2350),
            ("Hobbies", 5000, -5200),
            ("Parking", 1500, -1600),
        ]
        let budgetOrder: [(String, Int, Int)] = [
            ("Rent", 150_000, -150_000),
            ("Groceries & Household Supplies", 60000, -183_456),
            ("Utilities", 20000, -9611),
            ("Dining Out", 20000, -21550),
            ("Transport", 10000, -10820),
            ("Gifts", 5000, -5100),
            ("Pets", 3000, -3050),
            ("Clothing", 10000, -12400),
            ("Subscriptions", 2500, -2999),
            ("Coffee", 4000, -4650),
            ("Haircuts", 3500, -4000),
            ("Books", 2000, -2350),
        ]
        let format = FloatingPointFormatStyle<Double>.Currency(code: "USD").locale(Locale(identifier: "en_US"))
        let mask = "\u{2022}\u{2022}\u{2022}\u{2022}"
        let text: (Int) -> String = { balancesHidden ? mask : (Double($0) / 100).formatted(format) }
        return OverspentAlertsEntry(
            date: .now.addingTimeInterval(-300),
            balancesHidden: balancesHidden,
            categories: (balancesHidden ? budgetOrder : worstFirst).prefix(count).enumerated().map { index, row in
                WidgetCategoryBalance(
                    id: "preview-\(index)",
                    name: row.0,
                    available: row.1 + row.2,
                    formattedAvailable: text(row.1 + row.2),
                    budgeted: row.1,
                    spent: balancesHidden ? 0 : row.2,
                    formattedSpent: text(-row.2),
                    formattedBudgeted: text(row.1)
                )
            },
            hasSnapshot: true
        )
    }
}

#Preview("Small", as: .systemSmall) {
    OverspentAlertsWidget()
} timeline: {
    OverspentAlertsEntry.previewSample(count: 5)
    OverspentAlertsEntry.previewSample(count: 1)
    OverspentAlertsEntry.previewSample(count: 4, balancesHidden: true)
    OverspentAlertsEntry(date: .now, balancesHidden: false, categories: [], hasSnapshot: true)
    OverspentAlertsEntry(date: .now, balancesHidden: false, categories: [], hasSnapshot: false)
}

#Preview("Medium", as: .systemMedium) {
    OverspentAlertsWidget()
} timeline: {
    OverspentAlertsEntry.previewSample(count: 5)
    OverspentAlertsEntry.previewSample(count: 2)
    OverspentAlertsEntry.previewSample(count: 4, balancesHidden: true)
    OverspentAlertsEntry(date: .now, balancesHidden: false, categories: [], hasSnapshot: true)
    OverspentAlertsEntry(date: .now, balancesHidden: false, categories: [], hasSnapshot: false)
}

#Preview("Large", as: .systemLarge) {
    OverspentAlertsWidget()
} timeline: {
    OverspentAlertsEntry.previewSample(count: 12)
    OverspentAlertsEntry.previewSample(count: 3)
    OverspentAlertsEntry.previewSample(count: 12, balancesHidden: true)
    OverspentAlertsEntry(date: .now, balancesHidden: false, categories: [], hasSnapshot: true)
    OverspentAlertsEntry(date: .now, balancesHidden: false, categories: [], hasSnapshot: false)
}

@available(iOS 27.0, *)
#Preview("Extra Large Portrait", as: .systemExtraLargePortrait) {
    OverspentAlertsWidget()
} timeline: {
    OverspentAlertsEntry.previewSample(count: 12)
    OverspentAlertsEntry.previewSample(count: 3)
    OverspentAlertsEntry.previewSample(count: 12, balancesHidden: true)
    OverspentAlertsEntry(date: .now, balancesHidden: false, categories: [], hasSnapshot: true)
}
