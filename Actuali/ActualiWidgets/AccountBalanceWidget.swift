import AppIntents
import SwiftUI
import WidgetKit

struct AccountBalanceWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "AccountBalanceWidget",
            intent: SelectAccountsIntent.self,
            provider: AccountBalanceProvider()
        ) { entry in
            AccountBalanceWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Account Balances"))
        .description(String(localized: "Current balance for your chosen accounts."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct AccountBalanceEntry: TimelineEntry {
    let date: Date
    let balancesHidden: Bool
    let accounts: [WidgetAccountBalance]
    let hasSnapshot: Bool

    static let sample = AccountBalanceEntry(
        date: .now,
        balancesHidden: false,
        accounts: [
            WidgetAccountBalance(id: "checking", name: "Checking", balance: 245_300, formattedBalance: "$2,453.00", type: "checking", offBudget: false),
            WidgetAccountBalance(id: "savings", name: "Savings", balance: 1_500_000, formattedBalance: "$15,000.00", type: "savings", offBudget: false),
            WidgetAccountBalance(id: "credit", name: "Credit Card", balance: -42150, formattedBalance: "-$421.50", type: "credit", offBudget: false),
            WidgetAccountBalance(id: "invest", name: "Investment", balance: 3_200_000, formattedBalance: "$32,000.00", type: "investment", offBudget: true),
        ],
        hasSnapshot: true
    )
}

struct AccountBalanceProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AccountBalanceEntry {
        .sample
    }

    func snapshot(for configuration: SelectAccountsIntent, in context: Context) async -> AccountBalanceEntry {
        context.isPreview ? .sample : entry(for: configuration, in: context)
    }

    func timeline(for configuration: SelectAccountsIntent, in context: Context) async -> Timeline<AccountBalanceEntry> {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        return Timeline(entries: [entry(for: configuration, in: context)], policy: .after(nextMidnight))
    }

    private func entry(for configuration: SelectAccountsIntent, in context: Context) -> AccountBalanceEntry {
        let limit = context.family == .systemSmall ? 1 : 4
        guard let snapshot = WidgetSnapshotStore.standard()?.read() else {
            return AccountBalanceEntry(date: .now, balancesHidden: false, accounts: [], hasSnapshot: false)
        }
        let chosenIds = (configuration.accounts ?? []).map(\.id)
        return AccountBalanceEntry(
            date: snapshot.generatedAt,
            balancesHidden: snapshot.balancesHidden,
            accounts: snapshot.accounts(matching: chosenIds, limit: limit),
            hasSnapshot: true
        )
    }
}

struct AccountBalanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.locale) private var locale

    let entry: AccountBalanceEntry

    var body: some View {
        Group {
            if entry.accounts.isEmpty {
                emptyState
            } else if family == .systemSmall {
                smallLayout(entry.accounts[0])
            } else {
                mediumLayout
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "actuali://accounts"))
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "building.columns")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(entry.hasSnapshot
                ? String(localized: "No accounts to show")
                : String(localized: "Open Actuali to load your budget"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func smallLayout(_ account: WidgetAccountBalance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(account.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } icon: {
                Image(systemName: iconName(for: account.type))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(account.formattedBalance)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(balanceColor(for: account))
            Text(String(localized: "balance"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entry.accounts) { account in
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: account.type))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(account.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(account.formattedBalance)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(balanceColor(for: account))
                }
            }
            Spacer(minLength: 0)
            Text(String(
                format: String(localized: "Updated %@", locale: locale),
                WidgetDateFormatting.relative(entry.date, locale: locale)
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func balanceColor(for account: WidgetAccountBalance) -> Color {
        if entry.balancesHidden {
            return .primary
        }
        return account.balance < 0 ? .red : .primary
    }

    private nonisolated func iconName(for type: String) -> String {
        switch type {
        case "checking": "banknote"
        case "savings": "building.columns"
        case "credit": "creditcard"
        case "investment": "chart.line.uptrend.xyaxis"
        case "mortgage": "house"
        case "debt": "exclamationmark.triangle"
        default: "dollarsign.circle"
        }
    }
}
