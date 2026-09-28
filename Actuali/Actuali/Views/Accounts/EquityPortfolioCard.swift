import SwiftUI

/// Portfolio breakdown card for an investment/Demat account, showing real-time Yahoo Finance valuation,
/// invested cost basis, gain/loss metrics, and individual holding breakdown.
struct EquityPortfolioCard: View {
    @EnvironmentObject var budgetStore: BudgetStore

    let account: Account

    @State private var showingTradeSheet = false
    @State private var isRefreshing = false
    @State private var isReconciling = false

    private var holdings: [EquityHolding] {
        budgetStore.equityHoldings(for: account.id)
    }

    private var totalInvestedCents: Int {
        budgetStore.totalEquityInvestedCents(for: account.id)
    }

    private var totalMarketValueCents: Int {
        budgetStore.totalEquityMarketValueCents(for: account.id)
    }

    private var totalGainCents: Int {
        totalMarketValueCents - totalInvestedCents
    }

    private var totalReturnPercent: Double {
        guard totalInvestedCents > 0 else { return 0 }
        return (Double(totalGainCents) / Double(totalInvestedCents)) * 100.0
    }

    private var balanceDiscrepancyCents: Int {
        totalMarketValueCents - account.balance
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

                    // Balance Reconciliation Banner (if ledger balance differs from market value)
                    if balanceDiscrepancyCents != 0 {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "Ledger out of sync with market"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                                Text(String(format: String(localized: "Difference: %@"), budgetStore.formatCurrency(balanceDiscrepancyCents)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                Task {
                                    isReconciling = true
                                    await budgetStore.reconcileEquityToMarketValue(accountId: account.id)
                                    isReconciling = false
                                }
                            } label: {
                                if isReconciling {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text(String(localized: "Sync Balance"))
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.accentColor)
                                        .foregroundStyle(.white)
                                        .clipShape(Capsule())
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isReconciling)
                            .accessibilityIdentifier("accountEquity.reconcileButton")
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    Divider()

                    // Holdings List
                    VStack(spacing: 12) {
                        ForEach(holdings) { holding in
                            let quote = budgetStore.stockQuotes[holding.symbol]
                            let price = quote?.price ?? (Double(holding.averageCostCents) / 100.0)
                            let marketVal = holding.marketValueCents(currentPrice: price)
                            let gain = holding.unrealizedGainCents(currentPrice: price)
                            let returnPct = holding.returnPercentage(currentPrice: price)

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

                                    let sharesStr = holding.shares.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", holding.shares) : String(format: "%g", holding.shares)
                                    Text(String(format: String(localized: "%@ shares @ %@"), sharesStr, budgetStore.formatCurrency(holding.averageCostCents)))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(budgetStore.formatCurrency(marketVal))
                                        .font(.subheadline.weight(.semibold))

                                    HStack(spacing: 2) {
                                        Text(String(format: "%@%.1f%%", gain >= 0 ? "+" : "", returnPct))
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(gain >= 0 ? Color.green : Color.red)
                                    }
                                }
                            }
                            .accessibilityIdentifier("accountEquity.holding.\(holding.symbol)")
                        }
                    }
                } else {
                    // Empty State: No holdings detected yet
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
            await budgetStore.refreshEquityQuotes(for: account.id)
        }
        .sheet(isPresented: $showingTradeSheet) {
            AddStockTradeSheet(accountId: account.id)
                .environmentObject(budgetStore)
        }
    }
}
