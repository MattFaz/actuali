import SwiftUI
import WidgetKit

struct ToBeBudgetedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "ToBeBudgetedWidget",
            provider: ToBeBudgetedProvider()
        ) { entry in
            ToBeBudgetedWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "To Be Budgeted"))
        .description(String(localized: "Unallocated funds available to assign to categories."))
        .supportedFamilies(
            WidgetFamily.systemFamilies(adding: [.accessoryCircular, .accessoryRectangular, .accessoryInline])
        )
    }
}

struct ToBeBudgetedEntry: TimelineEntry {
    let date: Date
    let balancesHidden: Bool
    let toBudget: Int?
    let formattedToBudget: String?
    let formattedTotalBudgeted: String?
    /// Positive, like Top Spending's header: Monthly Spending's black
    /// figure rather than a black minus sign.
    let formattedTotalSpending: String?
    /// Categories with nothing budgeted this month, capped per family.
    let unbudgeted: [WidgetCategoryBalance]
    let hasSnapshot: Bool
    /// nil when the snapshot has no toBudget (tracking budget).
    let isTrackingBudget: Bool

    static let sample = ToBeBudgetedEntry(
        date: .now,
        balancesHidden: false,
        toBudget: 52340,
        formattedToBudget: "$523.40",
        formattedTotalBudgeted: "$3,200.00",
        formattedTotalSpending: "$1,842.00",
        unbudgeted: [
            WidgetCategoryBalance(id: "gifts", name: "Gifts", available: 0, formattedAvailable: "$0.00", budgeted: 0),
            WidgetCategoryBalance(id: "travel", name: "Travel", available: 25000, formattedAvailable: "$250.00", budgeted: 0),
        ],
        hasSnapshot: true,
        isTrackingBudget: false
    )
}

struct ToBeBudgetedProvider: TimelineProvider {
    func placeholder(in context: Context) -> ToBeBudgetedEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (ToBeBudgetedEntry) -> Void) {
        completion(context.isPreview ? .sample : currentEntry(for: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ToBeBudgetedEntry>) -> Void) {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [currentEntry(for: context.family)], policy: .after(nextMidnight)))
    }

    private func currentEntry(for family: WidgetFamily) -> ToBeBudgetedEntry {
        // Medium shows the budgeted/spending summary rather than rows.
        let limit = switch family {
        case .systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline: 0
        case .systemLarge: 5
        default: 8 // systemExtraLargePortrait; the case itself is iOS 27-only
        }
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              snapshot.isForMonth(containing: .now) else {
            return ToBeBudgetedEntry(
                date: .now, balancesHidden: false, toBudget: nil, formattedToBudget: nil,
                formattedTotalBudgeted: nil, formattedTotalSpending: nil, unbudgeted: [],
                hasSnapshot: false, isTrackingBudget: false
            )
        }
        return ToBeBudgetedEntry(
            date: snapshot.generatedAt,
            balancesHidden: snapshot.balancesHidden,
            toBudget: snapshot.toBudget,
            formattedToBudget: snapshot.formattedToBudget,
            formattedTotalBudgeted: snapshot.formattedTotalBudgeted,
            formattedTotalSpending: snapshot.formattedTotalSpending,
            unbudgeted: snapshot.unbudgetedCategories(limit: limit),
            hasSnapshot: true,
            isTrackingBudget: snapshot.toBudget == nil
        )
    }
}

struct ToBeBudgetedWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.locale) private var locale

    let entry: ToBeBudgetedEntry

    var body: some View {
        Group {
            if family == .systemMedium {
                listLayout { summary }
                    .containerBackground(.fill.tertiary, for: .widget)
            } else if family.isLarge {
                listLayout { unbudgetedRows }
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                AccessoryAmountView(
                    icon: "tray.and.arrow.down",
                    label: label,
                    value: entry.formattedToBudget,
                    placeholder: placeholder,
                    inlineFormat: inlineFormat,
                    color: tbbColor,
                    updateDate: entry.date,
                    locale: locale
                )
            }
        }
        .widgetURL(URL(string: "actuali://budget"))
    }

    /// Tracking budgets have no To Budget figure; they get a label instead of
    /// a total rather than a misleading $0.
    private var placeholder: String {
        if entry.isTrackingBudget {
            return String(localized: "Tracking Budget")
        }
        return entry.hasSnapshot ? String(localized: "—") : String(localized: "Open Actuali to load your budget")
    }

    /// Medium, Large and Extra Large Portrait share the header and footer;
    /// the body between them is the summary or the unbudgeted rows. Label and
    /// total share one line, like Net Worth, so Medium fits its summary.
    private func listLayout(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let total = entry.formattedToBudget {
                    Text(total)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .layoutPriority(1)
                        .foregroundStyle(tbbColor)
                } else {
                    Text(placeholder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
            Spacer(minLength: 0)
            WidgetUpdatedFooter(date: entry.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var summary: some View {
        if entry.hasSnapshot {
            summaryRow(String(localized: "Budgeted"), entry.formattedTotalBudgeted)
                .accessibilityIdentifier("toBeBudgetedWidget.budgeted")
            summaryRow(String(localized: "Spending"), entry.formattedTotalSpending)
                .accessibilityIdentifier("toBeBudgetedWidget.spent")
        }
    }

    private func summaryRow(_ title: String, _ amount: String?) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(amount ?? String(localized: "—"))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var unbudgetedRows: some View {
        if entry.hasSnapshot, entry.unbudgeted.isEmpty {
            Text(String(localized: "No categories to show"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        ForEach(entry.unbudgeted) { category in
            HStack {
                Text(category.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(category.formattedAvailable)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    // Truncate the name, never the balance, at large Dynamic Type sizes.
                    .layoutPriority(1)
                    .foregroundStyle(availableColor(for: category))
            }
            .accessibilityIdentifier("toBeBudgetedWidget.categoryRow")
        }
    }

    /// Category Balances' colours: red when overspent, green otherwise, and
    /// neutral when hidden so the mask doesn't leak the sign.
    private func availableColor(for category: WidgetCategoryBalance) -> Color {
        if entry.balancesHidden {
            return .primary
        }
        return category.isOverspent ? .red : .green
    }

    private var label: String {
        guard let toBudget = entry.toBudget else {
            return String(localized: "To Budget")
        }
        return toBudget < 0
            ? String(localized: "Overbudgeted")
            : String(localized: "To Budget")
    }

    private var inlineFormat: String {
        guard let toBudget = entry.toBudget, toBudget < 0 else {
            return String(localized: "To Budget: %@", locale: locale)
        }
        return String(localized: "Overbudgeted: %@", locale: locale)
    }

    private var tbbColor: Color {
        if entry.balancesHidden {
            return .primary
        }
        guard let toBudget = entry.toBudget else { return .primary }
        if toBudget < 0 {
            return .red
        }
        if toBudget == 0 {
            return .primary
        }
        return .green
    }
}
