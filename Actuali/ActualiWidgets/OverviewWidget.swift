import AppIntents
import SwiftUI
import WidgetKit

/// One at-a-glance summary of every other widget's headline data, so it
/// only makes sense at Extra Large Portrait — itself iOS 27-only, hence the
/// availability on the whole widget rather than a family check.
@available(iOS 27.0, *)
struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "OverviewWidget",
            intent: SelectCategoriesIntent.self,
            provider: OverviewProvider()
        ) { entry in
            OverviewWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Overview"))
        .description(String(localized: "Net worth, budget, accounts, categories, transactions, and bills at a glance."))
        .supportedFamilies([.systemExtraLargePortrait])
    }
}

struct OverviewEntry: TimelineEntry {
    let date: Date
    let balancesHidden: Bool
    let netWorth: Int?
    let formattedNetWorth: String?
    let toBudget: Int?
    /// nil for tracking budgets, which have no To Budget.
    let formattedToBudget: String?
    let formattedTotalSpending: String?
    let formattedTotalBudgeted: String?
    let spentFraction: Double
    let isOverbudget: Bool
    let accounts: [WidgetAccountBalance]
    let categories: [WidgetCategoryBalance]
    let transactions: [WidgetTransaction]
    let bills: [WidgetBillItem]
    let hasSnapshot: Bool

    static let sample = OverviewEntry(
        date: .now,
        balancesHidden: false,
        netWorth: 4_903_150,
        formattedNetWorth: "$49,031.50",
        toBudget: 62900,
        formattedToBudget: "$629.00",
        formattedTotalSpending: "$1,842.00",
        formattedTotalBudgeted: "$3,200.00",
        spentFraction: 184_200 / 320_000,
        isOverbudget: false,
        accounts: Array(AccountBalanceEntry.sample.accounts.prefix(3)),
        categories: CategoryBalanceEntry.sample.categories,
        transactions: RecentTransactionsEntry.sample.transactions,
        bills: UpcomingBillsEntry.sample.bills,
        hasSnapshot: true
    )

    static let empty = OverviewEntry(
        date: .now, balancesHidden: false, netWorth: nil, formattedNetWorth: nil, toBudget: nil,
        formattedToBudget: nil, formattedTotalSpending: nil, formattedTotalBudgeted: nil,
        spentFraction: 0, isOverbudget: false, accounts: [], categories: [], transactions: [], bills: [],
        hasSnapshot: false
    )
}

struct OverviewProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> OverviewEntry {
        .sample
    }

    func snapshot(for configuration: SelectCategoriesIntent, in context: Context) async -> OverviewEntry {
        context.isPreview ? .sample : entry(for: configuration)
    }

    func timeline(for configuration: SelectCategoriesIntent, in context: Context) async -> Timeline<OverviewEntry> {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        return Timeline(entries: [entry(for: configuration)], policy: .after(nextMidnight))
    }

    /// Fixed section sizes: one family, so no per-family limits.
    private func entry(for configuration: SelectCategoriesIntent) -> OverviewEntry {
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              snapshot.isForMonth(containing: .now) else {
            return .empty
        }
        return OverviewEntry(
            date: snapshot.generatedAt,
            balancesHidden: snapshot.balancesHidden,
            netWorth: snapshot.netWorth,
            formattedNetWorth: snapshot.formattedNetWorth,
            toBudget: snapshot.toBudget,
            formattedToBudget: snapshot.formattedToBudget,
            formattedTotalSpending: snapshot.formattedTotalSpending,
            formattedTotalBudgeted: snapshot.formattedTotalBudgeted,
            spentFraction: snapshot.spentFraction,
            isOverbudget: snapshot.isOverbudget,
            accounts: snapshot.accounts(matching: [], limit: 3),
            categories: snapshot.categories(matching: (configuration.categories ?? []).map(\.id), limit: 4),
            transactions: snapshot.latestTransactions(limit: 3),
            bills: snapshot.nextBills(limit: 3),
            hasSnapshot: true
        )
    }
}

struct OverviewWidgetView: View {
    @Environment(\.locale) private var locale

    let entry: OverviewEntry

    var body: some View {
        Group {
            if entry.hasSnapshot {
                // Thirteen rows under the headline overfill the widget above
                // X Large text, and the fixed order leaves no rows to drop the
                // way the list widgets do. Keep the user's size wherever it
                // fits, otherwise step down to the largest size that does.
                ViewThatFits(in: .vertical) {
                    content
                    content.dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    content.dynamicTypeSize(...DynamicTypeSize.xLarge)
                    content.dynamicTypeSize(...DynamicTypeSize.large)
                }
            } else {
                emptyState
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "actuali://budget"))
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "square.grid.2x2")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(String(localized: "Open Actuali to load your budget"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline
            section(String(localized: "Accounts"), icon: "building.columns", empty: String(localized: "No accounts to show"), rows: entry.accounts) { account in
                row(account.name, amount: account.formattedBalance, color: signColor(account.balance < 0 ? .red : .primary)) {
                    Image(systemName: AccountBalanceWidgetView.iconName(for: account.type))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .accessibilityIdentifier("overviewWidget.accountRow")
            }
            section(String(localized: "Categories"), icon: "chart.pie", empty: String(localized: "No categories to show"), rows: entry.categories) { category in
                row(category.name, amount: category.formattedAvailable, color: signColor(category.isOverspent ? .red : .green))
                    .accessibilityIdentifier("overviewWidget.categoryRow")
            }
            section(String(localized: "Recent Transactions"), icon: "list.bullet.rectangle", empty: String(localized: "No transactions yet"), rows: entry.transactions) { transaction in
                row(transaction.payeeName ?? "", detail: dateString(year: transaction.date / 10000, month: transaction.date / 100 % 100, day: transaction.date % 100),
                    amount: transaction.formattedAmount, color: signColor(transactionColor(transaction.amount)))
                    .accessibilityIdentifier("overviewWidget.transactionRow")
            }
            section(String(localized: "Upcoming Bills"), icon: "calendar.badge.clock", empty: String(localized: "No upcoming bills"), rows: entry.bills) { bill in
                row(bill.title, detail: dateString(year: bill.dueYear, month: bill.dueMonth, day: bill.dueDay),
                    amount: bill.formattedAmount, color: signColor(billColor(bill))) {
                        Circle()
                            .fill(statusColor(bill.status))
                            .frame(width: 6, height: 6)
                            // Upcoming Bills' 8pt gap between dot and title.
                            .padding(.trailing, 2)
                    }
                    .accessibilityIdentifier("overviewWidget.billRow")
            }
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

    /// Net Worth leads; To Budget and Spent sit side by side under it, with
    /// Monthly Spending's progress bar below Spent.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel(String(localized: "Net Worth"), icon: "chart.line.uptrend.xyaxis")
                Text(entry.formattedNetWorth ?? "—")
                    .font(.title.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(signColor(entry.netWorth.map { $0 < 0 ? .red : .green } ?? .primary))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("overviewWidget.netWorth")
            HStack(alignment: .top, spacing: 16) {
                stat(String(localized: "To Budget"), value: entry.formattedToBudget,
                     color: signColor(entry.toBudget.map { $0 < 0 ? .red : .green } ?? .primary))
                    .accessibilityIdentifier("overviewWidget.toBudget")
                VStack(alignment: .leading, spacing: 2) {
                    stat(String(localized: "Spent"), value: entry.formattedTotalSpending, color: signColor(entry.isOverbudget ? .red : .primary))
                    if let budgeted = entry.formattedTotalBudgeted {
                        progressBar
                        Text(String(format: String(localized: "of %@ budgeted", locale: locale), budgeted))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("overviewWidget.spent")
            }
            // Ideal height, or minimumScaleFactor shrinks Spent below To Budget.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Monthly Spending Medium's Income and Budgeted blocks.
    private func stat(_ title: String, value: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value ?? "—")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(value == nil ? .secondary : color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(signColor(entry.isOverbudget ? .red : .blue))
                    .frame(width: geo.size.width * entry.spentFraction)
            }
        }
        .frame(height: 5)
        .padding(.vertical, 2)
    }

    private func section<Row: Identifiable>(
        _ title: String, icon: String, empty: String, rows: [Row], @ViewBuilder row: @escaping (Row) -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel(title, icon: icon)
            if rows.isEmpty {
                Text(empty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, content: row)
        }
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        Label {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } icon: {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The leading view is the account's symbol or the bill's status dot,
    /// as in Account Balances and Upcoming Bills.
    private func row(
        _ title: String, detail: String? = nil, amount: String, color: Color,
        @ViewBuilder leading: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: 6) {
            leading()
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(amount)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                // Truncate the name, never the amount, at large Dynamic Type sizes.
                .layoutPriority(1)
                .foregroundStyle(color)
        }
    }

    /// Mirrors Upcoming Bills: income green, otherwise by due status.
    private func billColor(_ bill: WidgetBillItem) -> Color {
        bill.amount > 0 ? .green : statusColor(bill.status)
    }

    private func statusColor(_ status: WidgetBillItem.Status) -> Color {
        switch status {
        case .overdue: .red
        case .due: .orange
        case .upcoming: .secondary
        }
    }

    /// Mirrors Recent Transactions: income green, outflow red.
    private func transactionColor(_ amount: Int) -> Color {
        amount == 0 ? .primary : amount > 0 ? .green : .red
    }

    /// Every colour goes neutral when hidden so the mask doesn't leak a sign.
    private func signColor(_ color: Color) -> Color {
        entry.balancesHidden ? .primary : color
    }

    private func dateString(year: Int, month: Int, day: Int) -> String {
        guard let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) else { return "" }
        return date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }
}
