import Testing
@testable import Actuali

struct EquityTransactionParserTests {
    // MARK: - Symbol Extraction

    @Test func extractsPlainUppercaseTicker() {
        let extracted = EquityTransactionParser.extractSymbol(from: "AAPL")
        #expect(extracted?.symbol == "AAPL")
        #expect(extracted?.name == nil)
    }

    @Test func extractsForeignAndSpecialTickers() {
        let nse = EquityTransactionParser.extractSymbol(from: "RELIANCE.NS")
        #expect(nse?.symbol == "RELIANCE.NS")

        let btc = EquityTransactionParser.extractSymbol(from: "BTC-USD")
        // BTC-USD has a hyphen but mixed case in the first part — only matches plain branch
        // if all uppercase. "BTC-USD" IS all uppercase so it matches.
        #expect(btc?.symbol == "BTC-USD")

        let index = EquityTransactionParser.extractSymbol(from: "^NSEI")
        #expect(index?.symbol == "^NSEI")
    }

    @Test func extractsParenthesizedTickerWithName() {
        let match = EquityTransactionParser.extractSymbol(from: "Apple Inc. (AAPL)")
        #expect(match?.symbol == "AAPL")
        #expect(match?.name == "Apple Inc.")

        let vanguard = EquityTransactionParser.extractSymbol(from: "Vanguard S&P 500 ETF (VOO)")
        #expect(vanguard?.symbol == "VOO")
        #expect(vanguard?.name == "Vanguard S&P 500 ETF")
    }

    @Test func ignoresNonTickerPayees() {
        #expect(EquityTransactionParser.extractSymbol(from: nil) == nil)
        #expect(EquityTransactionParser.extractSymbol(from: "") == nil)
        #expect(EquityTransactionParser.extractSymbol(from: "Reconciliation") == nil)
        #expect(EquityTransactionParser.extractSymbol(from: "Reconciliation adjustment") == nil)
        #expect(EquityTransactionParser.extractSymbol(from: "Starting Balance") == nil)
        #expect(EquityTransactionParser.extractSymbol(from: "Transfer") == nil)
    }

    @Test func rejectsMixedCaseOrdinaryPayees() {
        // "T-Mobile" has lowercase letters — must not match plain ticker branch.
        #expect(EquityTransactionParser.extractSymbol(from: "T-Mobile") == nil)
        // Mixed case in parenthesized form can't produce a false positive because
        // the parenthesized branch requires a parenthesized ticker suffix.
        #expect(EquityTransactionParser.extractSymbol(from: "Amazon (Prime)") == nil)
    }

    // MARK: - Trade Note Parsing

    @Test func parsesStandardQuantityAndPrice() {
        let trade = EquityTransactionParser.parseTradeDetails(from: "10 shares @ 150.00")
        #expect(trade?.shares == 10.0)
        #expect(trade?.price == 150.0)
    }

    @Test func parsesFractionalShares() {
        let trade = EquityTransactionParser.parseTradeDetails(from: "1.254 shares @ $220.50")
        #expect(trade?.shares == 1.254)
        #expect(trade?.price == 220.50)
    }

    @Test func parsesAlternatePhrasing() {
        let t1 = EquityTransactionParser.parseTradeDetails(from: "Buy 25 shares @ ₹2900")
        #expect(t1?.shares == 25.0)

        let t2 = EquityTransactionParser.parseTradeDetails(from: "Sold 5 shares @ 160")
        #expect(t2?.shares == 5.0)
        #expect(t2?.price == 160.0)

        // Shares with no price — quantity still parsed
        let t3 = EquityTransactionParser.parseTradeDetails(from: "50 shares")
        #expect(t3?.shares == 50.0)
        #expect(t3?.price == nil)
    }

    @Test func rejectsPlainPriceNoteWithoutUnitKeyword() {
        // Bare "50 @ 10" must NOT create a trade — no "shares/units" keyword.
        let t = EquityTransactionParser.parseTradeDetails(from: "50 @ 10")
        #expect(t == nil)
    }

    // MARK: - Position Resolution & DCA

    private func makeTx(
        id: String,
        date: Int,
        payee: String,
        amount: Int,
        notes: String,
        tombstone: Bool = false,
        startingBalanceFlag: Bool = false
    ) -> Transaction {
        Transaction(
            id: id,
            accountId: "acct-demat",
            date: date,
            amount: amount,
            payeeId: nil,
            payeeName: payee,
            categoryId: nil,
            categoryName: nil,
            notes: notes,
            cleared: true,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: tombstone,
            sortOrder: nil,
            importedPayee: nil,
            startingBalanceFlag: startingBalanceFlag
        )
    }

    @Test func resolvesSingleBuyPosition() {
        let tx = makeTx(
            id: "tx-1",
            date: 20_260_115,
            payee: "AAPL",
            amount: 150_000, // $1,500.00
            notes: "10 shares @ $150.00"
        )

        let holdings = EquityTransactionParser.resolveHoldings(from: [tx])
        #expect(holdings.count == 1)
        #expect(holdings[0].symbol == "AAPL")
        #expect(holdings[0].shares == 10.0)
        #expect(holdings[0].totalInvestedCents == 150_000)
        #expect(holdings[0].averageCostCents == 15000) // $150.00
    }

    @Test func computesDollarCostAveragingOnMultipleBuys() {
        let buy1 = makeTx(
            id: "tx-1",
            date: 20_260_115,
            payee: "AAPL",
            amount: 100_000, // 10 shares @ $100 = $1,000
            notes: "10 shares @ 100"
        )
        let buy2 = makeTx(
            id: "tx-2",
            date: 20_260_215,
            payee: "AAPL",
            amount: 200_000, // 10 shares @ $200 = $2,000
            notes: "10 shares @ 200"
        )

        let holdings = EquityTransactionParser.resolveHoldings(from: [buy1, buy2])
        #expect(holdings.count == 1)
        #expect(holdings[0].shares == 20.0)
        #expect(holdings[0].totalInvestedCents == 300_000) // $3,000
        #expect(holdings[0].averageCostCents == 15000) // $150 average
    }

    @Test func handlesPartialSellWithProportionalCostBasisReduction() {
        let buy = makeTx(
            id: "tx-1",
            date: 20_260_115,
            payee: "AAPL",
            amount: 200_000, // 20 shares @ $100 = $2,000
            notes: "20 shares @ 100"
        )
        let sell = makeTx(
            id: "tx-2",
            date: 20_260_301,
            payee: "AAPL",
            amount: -50000, // cost basis of 5 shares @ $100
            notes: "Sold 5 shares @ 160"
        )

        let holdings = EquityTransactionParser.resolveHoldings(from: [buy, sell])
        #expect(holdings.count == 1)
        #expect(holdings[0].shares == 15.0)
        // 25% of shares sold, cost basis drops from $2,000 by 25% ($500) to $1,500
        #expect(holdings[0].totalInvestedCents == 150_000)
        #expect(holdings[0].averageCostCents == 10000) // still $100/share
    }

    @Test func excludesClosedPositions() {
        let buy = makeTx(
            id: "tx-1",
            date: 20_260_115,
            payee: "AAPL",
            amount: 100_000,
            notes: "10 shares @ 100"
        )
        let sell = makeTx(
            id: "tx-2",
            date: 20_260_301,
            payee: "AAPL",
            amount: -100_000, // cost basis of all shares
            notes: "Sold 10 shares @ 120"
        )

        let holdings = EquityTransactionParser.resolveHoldings(from: [buy, sell])
        #expect(holdings.isEmpty)
    }

    @Test func skipsTombstonesAndReconciliationRows() {
        let validBuy = makeTx(
            id: "tx-1",
            date: 20_260_115,
            payee: "AAPL",
            amount: 100_000,
            notes: "10 shares @ 100"
        )
        let tombstoned = makeTx(
            id: "tx-2",
            date: 20_260_120,
            payee: "AAPL",
            amount: 50000,
            notes: "5 shares @ 100",
            tombstone: true
        )
        let reconciliation = makeTx(
            id: "tx-3",
            date: 20_260_201,
            payee: "Reconciliation",
            amount: 25000,
            notes: "Market adjustment"
        )

        let holdings = EquityTransactionParser.resolveHoldings(from: [validBuy, tombstoned, reconciliation])
        #expect(holdings.count == 1)
        #expect(holdings[0].shares == 10.0)
    }

    // MARK: - Market Valuation Calculations

    @Test func calculatesMarketValueAndGains() {
        let holding = EquityHolding(
            symbol: "AAPL",
            name: "Apple Inc.",
            shares: 10.0,
            totalInvestedCents: 150_000 // $1,500.00
        )

        // Price at $200.00/share: Value = $2,000.00, Gain = +$500.00 (+33.33%)
        let marketValue = holding.marketValueCents(currentPrice: 200.0)
        #expect(marketValue == 200_000)

        let gain = holding.unrealizedGainCents(currentPrice: 200.0)
        #expect(gain == 50000)

        let percent = holding.returnPercentage(currentPrice: 200.0)
        #expect(abs(percent - 33.333) < 0.01)
    }
}
