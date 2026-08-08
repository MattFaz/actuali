import Foundation
import Testing
@testable import Actuali

/// Verifies the demo budget ships a valid, renderable Reports dashboard — the
/// seeded widget meta must parse to real widget types (never `.unsupported`)
/// and the engines must produce data from the seeded transactions.
// Serialized: every test seeds the same fixed "demo" budget directory, so they
// must not run in parallel against shared on-disk state.
@Suite(.serialized)
@MainActor
struct DemoDataSeederTests {

    private func seedAndOpen() throws -> BudgetDatabase {
        try DemoDataSeeder.seed()
        let dbPath = BudgetFileManager.shared.databasePath(for: DemoDataSeeder.budgetId)
        return try BudgetDatabase(path: dbPath)
    }

    @Test func seededDashboardWidgetsAllParseToSupportedTypes() async throws {
        let database = try seedAndOpen()
        let widgets = try await database.fetchWidgets()

        #expect(widgets.count == 7)
        for widget in widgets {
            if case .unsupported(_, let type) = widget {
                Issue.record("Seeded widget did not parse to a supported type: \(type)")
            }
        }

        // The exact curated set, in dashboard order (y ASC).
        #expect(widgets.map(\.typeLabel) == ["Notes", "Net Worth", "Cash Flow", "Summary", "Spending", "Spending", "Spending"])
    }

    @Test func seededWidgetsProduceDataFromDemoTransactions() async throws {
        let database = try seedAndOpen()
        let widgets = try await database.fetchWidgets()
        let transactions = try await database.fetchTransactionsForReports()
        let today = Date()

        var netWorthMeta: NetWorthMeta?
        var summaryMeta: SummaryMeta?
        for widget in widgets {
            if case .netWorth(_, let meta) = widget { netWorthMeta = meta }
            if case .summary(_, let meta) = widget { summaryMeta = meta }
        }

        // Net worth: the seeded starting balance + activity must yield a chartable
        // series (the NetWorthWidgetView requires >= 2 points to draw).
        let netWorth = try #require(netWorthMeta)
        #expect(NetWorthEngine.compute(meta: netWorth, transactions: transactions, today: today).points.count >= 2)

        // "Spent This Month" summary must sum to a non-zero (negative) amount.
        let summary = try #require(summaryMeta)
        #expect(SummaryEngine.compute(meta: summary, transactions: transactions, today: today).totalCents < 0)
    }
}
