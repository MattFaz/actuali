import Testing
@testable import Actuali

/// The providers read their row counts from WidgetRowLimits, and so do the
/// widget snapshot tests, so the two can't drift apart. These tests pin the
/// table itself: changing a widget's row count has to happen here too.
struct WidgetRowLimitsTests {
    private static let table: [(name: String, limits: WidgetRowLimits)] = [
        ("categoryBalance", .categoryBalance), ("accountBalance", .accountBalance),
        ("netWorth", .netWorth), ("toBeBudgeted", .toBeBudgeted), ("spendingSummary", .spendingSummary),
        ("upcomingBills", .upcomingBills), ("recentTransactions", .recentTransactions),
        ("largestTransactions", .largestTransactions), ("topSpending", .topSpending),
        ("overspentAlerts", .overspentAlerts), ("spendingMovers", .spendingMovers),
    ]

    /// The gallery's rows per family: Small, Medium, Large, Extra Large Portrait.
    @Test func rowLimitsAreTheWidgetGallerysCounts() {
        let expected: [String: [Int]] = [
            "categoryBalance": [1, 4, 8, 12],
            "accountBalance": [1, 4, 8, 12],
            "netWorth": [0, 3, 6, 10],
            "toBeBudgeted": [0, 0, 5, 8],
            "spendingSummary": [0, 0, 5, 8],
            "upcomingBills": [1, 3, 6, 12],
            "recentTransactions": [3, 4, 8, 12],
            "largestTransactions": [1, 3, 5, 8],
            "topSpending": [1, 3, 5, 8],
            "overspentAlerts": [1, 4, 8, 12],
            "spendingMovers": [0, 0, 1, 4],
        ]
        #expect(Set(Self.table.map(\.name)) == Set(expected.keys))
        for (name, limits) in Self.table {
            #expect(
                [limits.small, limits.medium, limits.large, limits.extraLargePortrait] == expected[name],
                "\(name)"
            )
        }
    }

    /// WidgetSnapshotBuilder caps every list at 12 (the snapshot's prefix(12)
    /// and rankedCategories), so a bigger limit would leave rows empty; and a
    /// larger family never shows fewer rows than a smaller one.
    @Test func noRowLimitAsksForMoreThanTheSnapshotHolds() {
        for (name, limits) in Self.table {
            let counts = [limits.small, limits.medium, limits.large, limits.extraLargePortrait]
            #expect(counts.allSatisfy { (0...12).contains($0) }, "\(name)")
            #expect(counts == counts.sorted(), "\(name)")
        }
    }
}
