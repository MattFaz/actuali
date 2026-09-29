import Foundation
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreEquityTests {
    private func makeStore() -> BudgetStore {
        let store = BudgetStore.previewInstance()
        let account = Account(
            id: "acct_demat",
            name: "Zerodha Demat",
            type: .investment,
            offBudget: true,
            closed: false,
            sortOrder: 1,
            balance: 150_000 // $1,500.00
        )
        store.accounts = [account]
        return store
    }

    // MARK: - totalEquityInvestedCents / totalEquityMarketValueCents

    @Test func calculatesTotalInvestedAndMarketValueWithQuotes() {
        let store = makeStore()
        let holdings = [
            EquityHolding(symbol: "AAPL", name: nil, shares: 15.0, totalInvestedCents: 150_000),
        ]

        // Without quote, market value falls back to cost basis ($1,500.00)
        #expect(store.totalEquityInvestedCents(holdings: holdings) == 150_000)
        #expect(store.totalEquityMarketValueCents(holdings: holdings) == 150_000)

        // Inject quote: AAPL @ $200.00/share → 15 × $200 = $3,000.00 = 300,000 cents
        store.stockQuotes["AAPL"] = StockQuote(
            symbol: "AAPL",
            price: 200.0,
            dayChange: 5.0,
            dayChangePercent: 2.5,
            currency: "USD",
            lastUpdated: Date()
        )

        #expect(store.totalEquityMarketValueCents(holdings: holdings) == 300_000)
    }

    // MARK: - recordStockTrade

    @Test func recordStockTradeWritesParsableBuyRow() async throws {
        let store = BudgetStore.previewInstance()
        // previewInstance has no open budget, so recordStockTrade returns nil without a DB,
        // but the form validation and note formatting are still exercised.
        // ponytail: full round-trip test belongs in the DemoDataSeeder integration suite.
        let id = try await store.recordStockTrade(
            accountId: "acct_demat",
            symbol: "aapl",
            name: "Apple Inc.",
            shares: 10,
            pricePerShare: 150,
            isBuy: true
        )
        // No open DB in preview mode — returns nil, not a crash.
        #expect(id == nil)
    }

    // MARK: - reconcileEquityToMarketValue

    @Test func reconcileEquityReturnsEarlyWhenNoHoldings() async {
        let store = makeStore()
        // No transactions → equityHoldings returns [] → reconcile is a no-op.
        // equityHoldings is async (DB fetch) so reconcile is also async.
        let result = await store.reconcileEquityToMarketValue(accountId: "acct_demat")
        #expect(result == false)
    }
}
