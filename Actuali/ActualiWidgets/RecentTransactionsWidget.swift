import SwiftUI
import WidgetKit

struct RecentTransactionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "RecentTransactionsWidget",
            provider: RecentTransactionsProvider()
        ) { entry in
            RecentTransactionsWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Recent Transactions"))
        .description(String(localized: "Your latest transactions across all accounts."))
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        let base: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
        if #available(iOS 27.0, *) {
            return base + [.systemExtraLargePortrait]
        }
        return base
    }
}

struct RecentTransactionsEntry: TimelineEntry {
    let date: Date
    let balancesHidden: Bool
    let transactions: [WidgetTransaction]
    /// This month's net spending as a positive amount, like Top Spending's
    /// header, shown as the Large and Extra Large Portrait header; masked
    /// upstream when balances are hidden.
    let formattedMonthTotal: String?
    let hasSnapshot: Bool

    static let sample = RecentTransactionsEntry(
        date: .now,
        balancesHidden: false,
        transactions: [
            WidgetTransaction(id: "1", payeeName: "Corner Café", categoryName: "Dining Out", amount: -1250, formattedAmount: "-$12.50", date: 20_261_124),
            WidgetTransaction(id: "2", payeeName: "Fresh Market", categoryName: "Groceries", amount: -6342, formattedAmount: "-$63.42", date: 20_261_123),
            WidgetTransaction(id: "3", payeeName: "Employer", categoryName: "Income", amount: 245_000, formattedAmount: "$2,450.00", date: 20_261_121),
        ],
        formattedMonthTotal: "$1,842.00",
        hasSnapshot: true
    )
}

struct RecentTransactionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentTransactionsEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentTransactionsEntry) -> Void) {
        completion(context.isPreview ? .sample : currentEntry(for: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentTransactionsEntry>) -> Void) {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [currentEntry(for: context.family)], policy: .after(nextMidnight)))
    }

    private func currentEntry(for family: WidgetFamily) -> RecentTransactionsEntry {
        let limit = switch family {
        case .systemSmall: 3
        case .systemMedium: 4
        case .systemLarge: 8
        default: 12 // systemExtraLargePortrait; the case itself is iOS 27-only
        }
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              snapshot.isForMonth(containing: .now) else {
            return RecentTransactionsEntry(date: .now, balancesHidden: false, transactions: [], formattedMonthTotal: nil, hasSnapshot: false)
        }
        return RecentTransactionsEntry(
            date: snapshot.generatedAt,
            balancesHidden: snapshot.balancesHidden,
            transactions: snapshot.latestTransactions(limit: limit),
            formattedMonthTotal: snapshot.formattedTotalSpending,
            hasSnapshot: true
        )
    }
}

struct RecentTransactionsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.locale) private var locale

    let entry: RecentTransactionsEntry

    var body: some View {
        Group {
            if entry.transactions.isEmpty {
                emptyState
            } else {
                listLayout
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "actuali://accounts"))
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "list.bullet.rectangle")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(entry.hasSnapshot
                ? String(localized: "No transactions yet")
                : String(localized: "Open Actuali to load your budget"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var listLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isLargeFamily, let total = entry.formattedMonthTotal {
                monthTotalHeader(total)
            }
            // Drop trailing rows rather than clip them when Dynamic Type (the
            // widget cap is XXX Large) leaves less height than the provider's
            // row limit needs. Newest transactions win.
            ViewThatFits(in: .vertical) {
                ForEach((1...entry.transactions.count).reversed(), id: \.self) { count in
                    transactionRows(entry.transactions.prefix(count))
                }
            }
            // Claim the height before the Spacer below, or the VStack splits
            // it between them and drops a row that fits.
            .layoutPriority(1)
            Spacer(minLength: 0)
            Text(String(
                format: String(localized: "Updated %@", locale: locale),
                WidgetDateFormatting.relative(entry.date, locale: locale)
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Large and Extra Large Portrait; `systemExtraLargePortrait` is iOS
    /// 27-only, so it's matched behind `#available` rather than a `switch` case.
    private var isLargeFamily: Bool {
        if family == .systemLarge {
            return true
        }
        if #available(iOS 27.0, *), family == .systemExtraLargePortrait {
            return true
        }
        return false
    }

    /// Net Worth's header pattern; black like Monthly Spending under budget.
    private func monthTotalHeader(_ total: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                Text(String(localized: "Monthly Spending"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "creditcard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(total)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recentTransactionsWidget.monthTotal")
    }

    private func transactionRows(_ transactions: ArraySlice<WidgetTransaction>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(transactions) { transaction in
                Group {
                    if family == .systemSmall {
                        smallRow(transaction)
                    } else {
                        mediumRow(transaction)
                    }
                }
                .accessibilityIdentifier("recentTransactionsWidget.transactionRow")
            }
        }
    }

    /// Small is too narrow for one line, so the category and date sit under
    /// the payee and amount.
    private func smallRow(_ transaction: WidgetTransaction) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(transaction.payeeName ?? "")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                amountText(transaction, font: .caption.weight(.semibold))
            }
            HStack(spacing: 4) {
                Text(transaction.categoryName ?? "")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(dateString(transaction.date))
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func mediumRow(_ transaction: WidgetTransaction) -> some View {
        HStack(spacing: 6) {
            Text(transaction.payeeName ?? "")
                .font(.subheadline)
                .lineLimit(1)
            Text(transaction.categoryName ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(dateString(transaction.date))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            amountText(transaction, font: .subheadline.weight(.semibold))
        }
    }

    /// Truncate the payee and category, never the amount.
    private func amountText(_ transaction: WidgetTransaction, font: Font) -> some View {
        Text(transaction.formattedAmount)
            .font(font)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(1)
            .foregroundStyle(amountColor(for: transaction))
    }

    /// Income green, outflow red, as the widget design standard sets.
    /// Hidden balances stay neutral so the sign does not leak.
    private func amountColor(for transaction: WidgetTransaction) -> Color {
        if entry.balancesHidden || transaction.amount == 0 {
            return .primary
        }
        return transaction.amount > 0 ? .green : .red
    }

    /// Dates arrive as YYYYMMDD integers, the budget file's format.
    private func dateString(_ date: Int) -> String {
        let comps = DateComponents(year: date / 10000, month: date / 100 % 100, day: date % 100)
        guard let day = Calendar.current.date(from: comps) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: day)
    }
}
