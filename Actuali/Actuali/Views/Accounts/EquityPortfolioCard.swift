import SwiftUI

/// Portfolio breakdown card for an investment/Demat account, showing real-time Yahoo Finance valuation,
/// invested cost basis, gain/loss metrics, and individual holding breakdown.
struct EquityPortfolioCard: View {
    @EnvironmentObject var budgetStore: BudgetStore

    let account: Account

    @State private var holdings: [EquityHolding] = []
    @State private var showingTradeSheet = false
    @State private var isRefreshing = false
    @State private var isReconciling = false

    private var totalInvestedCents: Int {
        budgetStore.totalEquityInvestedCents(holdings: holdings)
    }

    private var totalMarketValueCents: Int {
        budgetStore.totalEquityMarketValueCents(holdings: holdings)
    }

    private var totalGainCents: Int {
        totalMarketValueCents - totalInvestedCents
    }

    private var totalReturnPercent: Double {
        guard totalInvestedCents > 0 else { return 0 }
        return (Double(totalGainCents) / Double(totalInvestedCents)) * 100.0
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                // Top Header Row
                HStack(alignment: .center) {
                    Label(String(localized: "Stock Portfolio"), systemImage: "chart.line.uptrend.xyaxis")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            Task {
                                isRefreshing = true
                                await budgetStore.refreshEquityQuotes(for: account.id, forceRefresh: true)
                                holdings = await budgetStore.equityHoldings(for: account.id)
                                isRefreshing = false
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("accountEquity.refreshQuotes")
                    }

                    Button {
                        showingTradeSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text(String(localized: "Trade"))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("accountEquity.addTrade")
                }

                // Summary Numbers Grid
                if !holdings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Current Value"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(budgetStore.formatCurrency(totalMarketValueCents))
                                .font(.title.weight(.bold))
                                .accessibilityIdentifier("accountEquity.currentValue")

                            // Gain/Loss Pill
                            HStack(spacing: 2) {
                                Image(systemName: totalGainCents >= 0 ? "arrow.up.right" : "arrow.down.right")
                                    .font(.caption2.weight(.bold))
                                Text(String(format: "%@ (%.1f%%)", budgetStore.formatCurrency(abs(totalGainCents)), totalReturnPercent))
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(totalGainCents >= 0 ? Color.green.opacity(0.18) : Color.red.opacity(0.18))
                            .foregroundStyle(totalGainCents >= 0 ? Color.green : Color.red)
                            .clipShape(Capsule())
                        }

                        HStack {
                            Text(String(localized: "Invested:"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(budgetStore.formatCurrency(totalInvestedCents))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("accountEquity.invested")
                        }
                    }

                    Divider()

                    // Holdings List
                    VStack(spacing: 12) {
                        ForEach(holdings) { holding in
                            let quote = budgetStore.stockQuotes[holding.symbol]
                            // Skip currencies that don't match the budget currency to avoid silent mixing.
                            // ponytail: no FX conversion — show cost basis for mismatched quotes instead.
                            let priceInBudgetCurrency: Double? = {
                                guard let q = quote else { return nil }
                                guard q.currency == nil || q.currency == budgetStore.currencyCode else { return nil }
                                return q.price
                            }()
                            let price = priceInBudgetCurrency ?? (Double(holding.averageCostCents) / 100.0)
                            let usingFallback = priceInBudgetCurrency == nil && quote != nil
                            let marketVal = holding.marketValueCents(currentPrice: price)
                            let gain = holding.unrealizedGainCents(currentPrice: price)
                            let returnPct = holding.returnPercentage(currentPrice: price)
                            let sharesStr = holding.shares
                                .formatted(.number.precision(.fractionLength(0...4)))

                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(holding.symbol)
                                            .fontWeight(.bold)
                                        if let name = holding.name {
                                            Text(name)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }

                                    Text(String(format: String(localized: "%@ shares @ %@"), sharesStr, budgetStore.formatCurrency(holding.averageCostCents)))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    if usingFallback {
                                        Text(String(localized: "Live price unavailable (currency mismatch)"))
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(budgetStore.formatCurrency(marketVal))
                                        .font(.subheadline.weight(.semibold))

                                    Text(String(format: "%@%.1f%%", gain >= 0 ? "+" : "", returnPct))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(gain >= 0 ? Color.green : Color.red)
                                }
                            }
                            .accessibilityIdentifier("accountEquity.holding.\(holding.symbol)")
                        }
                    }
                } else {
                    // Empty State
                    VStack(alignment: .center, spacing: 8) {
                        Text(String(localized: "No stock holdings logged yet."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button {
                            showingTradeSheet = true
                        } label: {
                            Text(String(localized: "Log First Trade"))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("accountEquity.firstTrade")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            .padding(.vertical, 4)
        }
        .task {
            holdings = await budgetStore.equityHoldings(for: account.id)
            await budgetStore.refreshEquityQuotes(for: account.id)
        }
        .onChange(of: budgetStore.dataVersion) {
            Task {
                holdings = await budgetStore.equityHoldings(for: account.id)
            }
        }
        .sheet(isPresented: $showingTradeSheet) {
            AddStockTradeSheet(accountId: account.id)
                .environmentObject(budgetStore)
        }
    }
}
