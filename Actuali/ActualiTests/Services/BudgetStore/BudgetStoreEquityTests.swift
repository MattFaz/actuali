import Foundation
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreEquityTests {
    private func makeStoreWithTransactions() -> BudgetStore {
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
        let buy1 = Transaction(
            id: "tx-1",
            accountId: "acct_demat",
            date: 20_260_115,
            amount: 100_000, // 10 shares @ $100
            payeeName: "AAPL",
            notes: "10 shares @ 100",
            cleared: true,
            reconciled: false
        )
        let buy2 = Transaction(
            id: "tx-2",
            accountId: "acct_demat",
            date: 20_260_215,
            amount: 50000, // 5 shares @ $100
            payeeName: "AAPL",
            notes: "5 shares @ 100",
            cleared: true,
            reconciled: false
        )

        store.accounts = [account]
        store.transactions = [buy1, buy2]
        return store
    }

    @Test func resolvesHoldingsForInvestmentAccount() {
        let store = makeStoreWithTransactions()
        let holdings = store.equityHoldings(for: "acct_demat")

        #expect(holdings.count == 1)
        #expect(holdings[0].symbol == "AAPL")
        #expect(holdings[0].shares == 15.0)
        #expect(holdings[0].totalInvestedCents == 150_000)
    }

    @Test func memoizesHoldingsUntilDataVersionChanges() {
        let store = makeStoreWithTransactions()

        let first = store.equityHoldings(for: "acct_demat")
        #expect(store.memoizedHoldings["acct_demat"]?.count == 1)

        // Adding an irrelevant transaction in another account shouldn't break memoization until dataVersion bumps
        let second = store.equityHoldings(for: "acct_demat")
        #expect(first == second)

        // Bump dataVersion
        store.dataVersion += 1
        let third = store.equityHoldings(for: "acct_demat")
        #expect(third.count == 1)
    }

    @Test func calculatesTotalInvestedAndMarketValueWithQuotes() {
        let store = makeStoreWithTransactions()
        #expect(store.totalEquityInvestedCents(for: "acct_demat") == 150_000)

        // Without quote, market value falls back to cost basis ($1,500.00)
        #expect(store.totalEquityMarketValueCents(for: "acct_demat") == 150_000)

        // Provide quote: AAPL @ $200.00/share (15 shares * $200 = $3,000.00 = 300,000 cents)
        store.stockQuotes["AAPL"] = StockQuote(
            symbol: "AAPL",
            price: 200.0,
            dayChange: 5.0,
            dayChangePercent: 2.5,
            currency: "USD",
            lastUpdated: Date()
        )

        #expect(store.totalEquityMarketValueCents(for: "acct_demat") == 300_000)
    }
}
