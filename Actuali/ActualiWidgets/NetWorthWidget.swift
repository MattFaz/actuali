import SwiftUI
import WidgetKit

struct NetWorthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "NetWorthWidget",
            provider: NetWorthProvider()
        ) { entry in
            NetWorthWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Net Worth"))
        .description(String(localized: "Total balance across all your accounts."))
        .supportedFamilies(
            WidgetFamily.systemFamilies(adding: [.accessoryCircular, .accessoryRectangular, .accessoryInline])
        )
    }
}

struct NetWorthEntry: TimelineEntry {
    let date: Date
    let balancesHidden: Bool
    let netWorth: Int?
    let formattedNetWorth: String?
    let accounts: [WidgetAccountBalance]
    let hasSnapshot: Bool

    /// Reuses the Account Balances sample: its on-budget rows plus the
    /// off-budget investment add up to this total.
    static let sample = NetWorthEntry(
        date: .now,
        balancesHidden: false,
        netWorth: 4_903_150,
        formattedNetWorth: "$49,031.50",
        accounts: AccountBalanceEntry.sample.accounts.filter { !$0.offBudget },
        hasSnapshot: true
    )
}

struct NetWorthProvider: TimelineProvider {
    func placeholder(in context: Context) -> NetWorthEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (NetWorthEntry) -> Void) {
        completion(context.isPreview ? .sample : currentEntry(for: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NetWorthEntry>) -> Void) {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [currentEntry(for: context.family)], policy: .after(nextMidnight)))
    }

    private func currentEntry(for family: WidgetFamily) -> NetWorthEntry {
        let limit = WidgetRowLimits.netWorth.rows(for: family)
        guard let snapshot = WidgetSnapshotStore.standard()?.read() else {
            return NetWorthEntry(date: .now, balancesHidden: false, netWorth: nil, formattedNetWorth: nil, accounts: [], hasSnapshot: false)
        }
        return NetWorthEntry(
            date: snapshot.generatedAt,
            balancesHidden: snapshot.balancesHidden,
            netWorth: snapshot.netWorth,
            formattedNetWorth: snapshot.formattedNetWorth,
            // There's no account picker here, so this takes the same
            // fallback as a fresh Account Balances widget — on-budget accounts
            // in sidebar order. Off-budget accounts count toward the total but
            // never get a row; ranking by balance would need its own selector.
            accounts: snapshot.accounts(matching: [], limit: limit),
            hasSnapshot: true
        )
    }
}

struct NetWorthWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.locale) private var locale

    let entry: NetWorthEntry

    var body: some View {
        Group {
            if showsAccountList {
                listLayout
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                AccessoryAmountView(
                    icon: "chart.line.uptrend.xyaxis",
                    label: String(localized: "Net Worth"),
                    value: entry.formattedNetWorth,
                    placeholder: placeholder,
                    inlineFormat: String(localized: "Net Worth: %@", locale: locale),
                    color: netWorthColor,
                    updateDate: entry.date,
                    locale: locale
                )
            }
        }
        .widgetURL(URL(string: "actuali://accounts"))
    }

    private var showsAccountList: Bool {
        family == .systemMedium || family.isLarge
    }

    private var placeholder: String {
        entry.hasSnapshot ? String(localized: "—") : String(localized: "Open Actuali to load your budget")
    }

    /// Medium, large, and extra-large portrait share this layout; only the
    /// provider's row limit differs per family. Label and total share one
    /// line because a stacked header plus three rows overfills Medium.
    private var listLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(String(localized: "Net Worth"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let total = entry.formattedNetWorth {
                    Text(total)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .layoutPriority(1)
                        .foregroundStyle(netWorthColor)
                } else {
                    Text(placeholder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if entry.hasSnapshot, entry.accounts.isEmpty {
                Text(String(localized: "No accounts to show"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(entry.accounts) { account in
                HStack(spacing: 6) {
                    Image(systemName: AccountBalanceWidgetView.iconName(for: account.type))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(account.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(account.formattedBalance)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        // Truncate the name, never the balance, at large Dynamic Type sizes.
                        .layoutPriority(1)
                        .foregroundStyle(balanceColor(for: account))
                }
                .accessibilityIdentifier("netWorthWidget.accountRow")
            }
            Spacer(minLength: 0)
            WidgetUpdatedFooter(date: entry.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var netWorthColor: Color {
        if entry.balancesHidden {
            return .primary
        }
        guard let netWorth = entry.netWorth else { return .primary }
        return netWorth < 0 ? .red : .green
    }

    /// Same as the Account Balances rows: red for negative balances, muted
    /// to neutral when hidden so the mask doesn't leak the sign.
    private func balanceColor(for account: WidgetAccountBalance) -> Color {
        if entry.balancesHidden {
            return .primary
        }
        return account.balance < 0 ? .red : .primary
    }
}
