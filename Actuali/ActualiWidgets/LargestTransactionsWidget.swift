import SwiftUI
import WidgetKit

struct LargestTransactionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "LargestTransactionsWidget",
            provider: LargestTransactionsProvider()
        ) { entry in
            LargestTransactionsWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Largest Transactions"))
        .description(String(localized: "Your biggest purchases this month."))
        .supportedFamilies(WidgetFamily.systemFamilies())
    }
}

struct LargestTransactionsEntry: TimelineEntry {
    let date: Date
    /// When true the rows arrive newest first rather than largest first, so
    /// the header stops claiming they're the largest.
    let balancesHidden: Bool
    let transactions: [WidgetTransaction]
    let hasSnapshot: Bool
    /// This month's net spending as a positive amount, like Top Spending's
    /// header, shown above the Large and Extra Large Portrait rows; masked
    /// upstream when balances are hidden. Defaulted so the Small and Medium
    /// entries don't have to spell it out.
    var formattedTotalSpending: String?

    static let sample = LargestTransactionsEntry(
        date: .now,
        balancesHidden: false,
        transactions: [
            WidgetTransaction(id: "1", payeeName: "Landlord", categoryName: "Rent", amount: -145_000, formattedAmount: "-$1,450.00", date: 20_261_101),
            WidgetTransaction(id: "2", payeeName: "Fresh Market", categoryName: "Groceries", amount: -18342, formattedAmount: "-$183.42", date: 20_261_118),
            WidgetTransaction(id: "3", payeeName: "City Power", categoryName: "Utilities", amount: -9611, formattedAmount: "-$96.11", date: 20_261_109),
        ],
        hasSnapshot: true,
        formattedTotalSpending: "$1,842.00"
    )
}

struct LargestTransactionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> LargestTransactionsEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (LargestTransactionsEntry) -> Void) {
        completion(context.isPreview ? .sample : currentEntry(for: context.family))
    }

    /// The list is this month's, so it goes stale when the month rolls over
    /// even without new data; the app's write reloads it sooner.
    func getTimeline(in context: Context, completion: @escaping (Timeline<LargestTransactionsEntry>) -> Void) {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [currentEntry(for: context.family)], policy: .after(nextMidnight)))
    }

    private func currentEntry(for family: WidgetFamily) -> LargestTransactionsEntry {
        let limit = switch family {
        case .systemSmall: 1
        case .systemMedium: 3
        case .systemLarge: 5
        default: 8 // systemExtraLargePortrait; the case itself is iOS 27-only
        }
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              snapshot.isForMonth(containing: .now) else {
            return LargestTransactionsEntry(date: .now, balancesHidden: false, transactions: [], hasSnapshot: false)
        }
        return LargestTransactionsEntry(
            date: snapshot.generatedAt,
            balancesHidden: snapshot.balancesHidden,
            transactions: snapshot.largestTransactions(limit: limit),
            hasSnapshot: true,
            formattedTotalSpending: snapshot.formattedTotalSpending
        )
    }
}

struct LargestTransactionsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.locale) private var locale

    let entry: LargestTransactionsEntry

    var body: some View {
        Group {
            if let largest = entry.transactions.first {
                if family == .systemSmall {
                    smallLayout(largest)
                } else if family.isLarge {
                    largeLayout
                } else {
                    mediumLayout
                }
            } else {
                emptyState
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "actuali://accounts"))
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "arrow.up.right.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(entry.hasSnapshot
                ? String(localized: "No spending this month yet")
                : String(localized: "Open Actuali to load your budget"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func smallLayout(_ transaction: WidgetTransaction) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.formattedAmount)
                    .foregroundStyle(amountColor(for: transaction))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(transaction.payeeName ?? "")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(detail(transaction))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("largestTransactionsWidget.transactionRow")
            Spacer(minLength: 0)
            WidgetUpdatedFooter(date: entry.date)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            // Drop trailing rows rather than clip them when Dynamic Type
            // leaves less height than three rows need. The largest wins.
            ViewThatFits(in: .vertical) {
                ForEach((1...entry.transactions.count).reversed(), id: \.self) { count in
                    mediumRows(entry.transactions.prefix(count))
                }
            }
            // Claim the height before the Spacer below, or the VStack splits
            // it between them and drops a row that fits.
            .layoutPriority(1)
            Spacer(minLength: 0)
            WidgetUpdatedFooter(date: entry.date)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One line per row: three two-line rows plus header and footer overrun
    /// Medium's height at the default text size and lose the third row.
    private func mediumRows(_ transactions: ArraySlice<WidgetTransaction>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(transactions) { transaction in
                HStack(spacing: 6) {
                    Text(transaction.payeeName ?? "")
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(transaction.categoryName ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(WidgetDateFormatting.shortDate(transaction.date, locale: locale) ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // Truncate the payee and category, never the amount.
                    Text(transaction.formattedAmount)
                        .foregroundStyle(amountColor(for: transaction))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("largestTransactionsWidget.transactionRow")
            }
        }
    }

    /// Large and Extra Large Portrait: the month's total, then the rows
    /// pinned to the top, leaving any spare height above the footer as
    /// Category Balances does.
    private var largeLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let total = entry.formattedTotalSpending {
                totalSpentHeader(total)
            }
            // Drop trailing rows rather than clip them when Dynamic Type (the
            // widget cap is XXX Large) leaves less height than the provider's
            // row limit needs. The largest wins.
            ViewThatFits(in: .vertical) {
                ForEach((1...entry.transactions.count).reversed(), id: \.self) { count in
                    largeRows(entry.transactions.prefix(count))
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            WidgetUpdatedFooter(date: entry.date)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A row like To Be Budgeted's summary, since the widget's own header
    /// already sits above it. Black and unsigned, like Monthly Spending
    /// under budget.
    private func totalSpentHeader(_ total: String) -> some View {
        HStack {
            Text(String(localized: "Monthly Spending"))
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(total)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("largestTransactionsWidget.totalSpent")
    }

    /// Two lines per row, the width Medium lacks: payee and amount, then
    /// category and date, so long names keep more of themselves.
    private func largeRows(_ transactions: ArraySlice<WidgetTransaction>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(transactions) { transaction in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(transaction.payeeName ?? "")
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        // Truncate the payee, never the amount.
                        Text(transaction.formattedAmount)
                            .foregroundStyle(amountColor(for: transaction))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    Text(detail(transaction))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("largestTransactionsWidget.transactionRow")
            }
        }
    }

    /// Outflow red, income green, as the widget design standard sets.
    /// Hidden balances stay neutral so the sign does not leak.
    private func amountColor(for transaction: WidgetTransaction) -> Color {
        if entry.balancesHidden || transaction.amount == 0 {
            return .primary
        }
        return transaction.amount > 0 ? .green : .red
    }

    /// Small drops "Transactions", which otherwise truncates at default text
    /// size. Hidden balances order by date, so the header says so rather
    /// than calling the newest purchases the largest.
    private var header: some View {
        Label {
            Text(headerTitle)
                .font(.caption.weight(.medium))
        } icon: {
            Image(systemName: "arrow.up.right.circle")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var headerTitle: String {
        if entry.balancesHidden {
            return String(localized: "Recent Spending")
        }
        return family == .systemSmall ? String(localized: "Largest") : String(localized: "Largest Transactions")
    }

    /// Category and date on one line; a hidden category arrives nil,
    /// leaving just the date.
    private func detail(_ transaction: WidgetTransaction) -> String {
        [transaction.categoryName, WidgetDateFormatting.shortDate(transaction.date, locale: locale)]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
