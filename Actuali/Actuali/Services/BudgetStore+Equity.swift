import Foundation

// MARK: - Equity / Demat Portfolio Operations

extension BudgetStore {
    /// Returns the resolved stock holdings for the specified investment account.
    /// Memoized against `dataVersion` so repeated calls during scrolling/renders are O(1).
    func equityHoldings(for accountId: String) -> [EquityHolding] {
        if memoizedHoldingsDataVersion == dataVersion, let cached = memoizedHoldings[accountId] {
            return cached
        }
        if memoizedHoldingsDataVersion != dataVersion {
            memoizedHoldings.removeAll(keepingCapacity: true)
            memoizedHoldingsDataVersion = dataVersion
        }

        let accountTransactions = transactions.filter { $0.accountId == accountId }
        let resolved = EquityTransactionParser.resolveHoldings(from: accountTransactions)
        memoizedHoldings[accountId] = resolved
        return resolved
    }

    /// Fetches live market quotes for all symbols held in the given account.
    func refreshEquityQuotes(for accountId: String, forceRefresh: Bool = false) async {
        let holdings = equityHoldings(for: accountId)
        let symbols = holdings.map(\.symbol)
        guard !symbols.isEmpty else { return }

        let fetched = await yahooFinanceClient.quotes(for: symbols, forceRefresh: forceRefresh)
        for (sym, quote) in fetched {
            stockQuotes[sym] = quote
        }
    }

    /// Total market value of all held stocks in the account, in cents.
    /// Falls back to cost basis for symbols without a loaded quote.
    func totalEquityMarketValueCents(for accountId: String) -> Int {
        let holdings = equityHoldings(for: accountId)
        return holdings.reduce(0) { total, holding in
            let price = stockQuotes[holding.symbol]?.price ?? (Double(holding.averageCostCents) / 100.0)
            return total + holding.marketValueCents(currentPrice: price)
        }
    }

    /// Total invested cost basis across all open positions in the account, in cents.
    func totalEquityInvestedCents(for accountId: String) -> Int {
        let holdings = equityHoldings(for: accountId)
        return holdings.reduce(0) { $0 + $1.totalInvestedCents }
    }

    /// Reconciles the account ledger balance to the current market value of all held stocks.
    /// Creates a standard reconciliation adjustment transaction for the difference.
    @discardableResult
    func reconcileEquityToMarketValue(accountId: String) async -> Bool {
        guard let account = accounts.first(where: { $0.id == accountId }) else { return false }
        let holdings = equityHoldings(for: accountId)
        guard !holdings.isEmpty else { return false }

        let marketValue = totalEquityMarketValueCents(for: accountId)
        let difference = marketValue - account.balance
        guard difference != 0 else { return true }

        return await createReconciliationAdjustment(accountId: accountId, amountCents: difference)
    }

    /// Records a stock buy or sell as a native Actual Budget transaction in the account.
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

        let totalAmount = shares * pricePerShare
        let payeeText = name != nil && !name!.isEmpty ? "\(name!) (\(cleanSymbol))" : cleanSymbol

        // Format note cleanly: e.g. "10 shares @ 150.00" or "Sold 5 shares @ 180.00"
        let noteText: String
        let formattedPrice = String(format: "%.2f", pricePerShare)
        let formattedShares = shares.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", shares) : String(format: "%g", shares)

        if isBuy {
            noteText = "\(formattedShares) shares @ \(formattedPrice)"
        } else {
            noteText = "Sold \(formattedShares) shares @ \(formattedPrice)"
        }

        let form = TransactionForm(
            accountId: accountId,
            type: isBuy ? .income : .expense, // Inflow for buy (asset added), outflow for sell
            amount: String(format: "%.2f", totalAmount),
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
