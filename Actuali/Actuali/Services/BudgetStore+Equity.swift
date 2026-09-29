import Foundation

// MARK: - Equity / Demat Portfolio Operations

extension BudgetStore {
    /// Returns the resolved stock holdings for the specified investment account.
    /// Fetches all account transactions directly from the database (bypasses the
    /// 500-row in-memory page) so old buy transactions are never missed.
    func equityHoldings(for accountId: String) async -> [EquityHolding] {
        guard let database = databaseForLogger else { return [] }
        let allTx = await (try? database.fetchTransactions(accountId: accountId, limit: .max)) ?? []
        return EquityTransactionParser.resolveHoldings(from: allTx)
    }

    /// Fetches live market quotes for all symbols held in the given account.
    func refreshEquityQuotes(for accountId: String, forceRefresh: Bool = false) async {
        let holdings = await equityHoldings(for: accountId)
        let symbols = holdings.map(\.symbol)
        guard !symbols.isEmpty else { return }

        let fetched = await yahooFinanceClient.quotes(for: symbols, forceRefresh: forceRefresh)
        for (sym, quote) in fetched {
            stockQuotes[sym] = quote
        }
    }

    /// Total market value of all held stocks in the account, in cents.
    /// Falls back to cost basis for symbols without a loaded quote.
    func totalEquityMarketValueCents(holdings: [EquityHolding]) -> Int {
        holdings.reduce(0) { total, holding in
            let price = stockQuotes[holding.symbol]?.price ?? (Double(holding.averageCostCents) / 100.0)
            return total + holding.marketValueCents(currentPrice: price)
        }
    }

    /// Total invested cost basis across all open positions, in cents.
    func totalEquityInvestedCents(holdings: [EquityHolding]) -> Int {
        holdings.reduce(0) { $0 + $1.totalInvestedCents }
    }

    /// Reconciles the equity positions to their current market value by recording the
    /// unrealized gain/loss (market value − cost basis) as a reconciliation adjustment.
    /// Only the equity delta is recorded; cash and other non-equity rows are untouched.
    @discardableResult
    func reconcileEquityToMarketValue(accountId: String) async -> Bool {
        let holdings = await equityHoldings(for: accountId)
        guard !holdings.isEmpty else { return false }

        let marketValue = totalEquityMarketValueCents(holdings: holdings)
        let invested = totalEquityInvestedCents(holdings: holdings)
        let gainLoss = marketValue - invested
        guard gainLoss != 0 else { return true }

        return await createReconciliationAdjustment(accountId: accountId, amountCents: gainLoss)
    }

    /// Records a stock buy or sell as a native Actual Budget transaction in the account.
    ///
    /// **Buy**: records the full cost as an inflow (asset added to account).
    /// **Sell**: records the *cost basis* of the sold shares as an outflow (asset removed).
    ///   The realized gain/loss is booked separately via `reconcileEquityToMarketValue`.
    ///   This keeps the account balance non-negative between trades.
    @discardableResult
    func recordStockTrade(
        accountId: String,
        symbol: String,
        name: String? = nil,
        shares: Double,
        pricePerShare: Double,
        date: Date = Date(),
        isBuy: Bool = true
    ) async throws -> String? {
        let cleanSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanSymbol.isEmpty, shares > 0, pricePerShare > 0 else { return nil }

        let payeeText = name != nil && !name!.isEmpty ? "\(name!) (\(cleanSymbol))" : cleanSymbol

        // Format note: "10 shares @ 150.00" or "Sold 5 shares @ 180.00"
        let formattedPrice = String(format: "%.2f", pricePerShare)
        let formattedShares = shares.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", shares)
            : String(format: "%g", shares)
        let noteText = isBuy
            ? "\(formattedShares) shares @ \(formattedPrice)"
            : "Sold \(formattedShares) shares @ \(formattedPrice)"

        // Amount to record:
        // Buy  → full cost (shares × price), so the account balance grows by the invested amount.
        // Sell → cost basis of the shares sold, recorded as outflow, so balance shrinks by basis.
        //        The realized gain is NOT included here; use reconcileEquityToMarketValue after.
        let amount: Double
        if isBuy {
            amount = shares * pricePerShare
        } else {
            // Need the current average cost to compute cost basis for this lot.
            let holdings = await equityHoldings(for: accountId)
            let holding = holdings.first { $0.symbol == cleanSymbol }
            let avgCostPerShare = holding.map { Double($0.averageCostCents) / 100.0 } ?? pricePerShare
            amount = min(shares, holding?.shares ?? shares) * avgCostPerShare
        }

        let form = TransactionForm(
            accountId: accountId,
            type: isBuy ? .income : .expense,
            amount: String(format: "%.2f", amount),
            payeeName: payeeText,
            transferToAccountId: nil,
            categoryId: nil,
            notes: noteText,
            date: date,
            cleared: true
        )

        return try await saveTransaction(form)
    }
}
