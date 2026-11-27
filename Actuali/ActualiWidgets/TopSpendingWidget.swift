import SwiftUI
import WidgetKit

struct TopSpendingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "TopSpendingWidget",
            provider: TopSpendingProvider()
        ) { entry in
            TopSpendingWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Top Spending"))
        .description(String(localized: "The categories you've spent the most in this month."))
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

struct TopSpendingEntry: TimelineEntry {
    let date: Date
    let balancesHidden: Bool
    let categories: [WidgetCategoryBalance]
    /// This month's total spending as a positive amount, like the rows,
    /// shown as the Large and Extra Large Portrait header; masked upstream
    /// when balances are hidden.
    let formattedTotalSpending: String?
    let hasSnapshot: Bool

    static let sample = TopSpendingEntry(
        date: .now,
        balancesHidden: false,
        categories: [
            WidgetCategoryBalance(
                id: "groceries", name: "Groceries", available: 8020, formattedAvailable: "$80.20",
                budgeted: 50000, spent: -41980, formattedSpent: "$419.80", formattedBudgeted: "$500.00"
            ),
            WidgetCategoryBalance(
                id: "dining", name: "Dining Out", available: -1550, formattedAvailable: "-$15.50",
                budgeted: 20000, spent: -21550, formattedSpent: "$215.50", formattedBudgeted: "$200.00"
            ),
            WidgetCategoryBalance(
                id: "transport", name: "Transport", available: 4000, formattedAvailable: "$40.00",
                budgeted: 10000, spent: -6000, formattedSpent: "$60.00", formattedBudgeted: "$100.00"
            ),
        ],
        formattedTotalSpending: "$1,842.00",
        hasSnapshot: true
    )
}

struct TopSpendingProvider: TimelineProvider {
    func placeholder(in context: Context) -> TopSpendingEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (TopSpendingEntry) -> Void) {
        completion(context.isPreview ? .sample : currentEntry(for: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TopSpendingEntry>) -> Void) {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [currentEntry(for: context.family)], policy: .after(nextMidnight)))
    }

    private func currentEntry(for family: WidgetFamily) -> TopSpendingEntry {
        let limit = switch family {
        case .systemSmall: 1
        case .systemMedium: 3
        case .systemLarge: 5
        default: 8 // systemExtraLargePortrait; the case itself is iOS 27-only
        }
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              snapshot.isForMonth(containing: .now) else {
            return TopSpendingEntry(date: .now, balancesHidden: false, categories: [], formattedTotalSpending: nil, hasSnapshot: false)
        }
        return TopSpendingEntry(
            date: snapshot.generatedAt,
            balancesHidden: snapshot.balancesHidden,
            categories: snapshot.topSpendingCategories(limit: limit),
            formattedTotalSpending: snapshot.formattedTotalSpending,
            hasSnapshot: true
        )
    }
}

struct TopSpendingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.locale) private var locale

    let entry: TopSpendingEntry

    var body: some View {
        Group {
            if entry.categories.isEmpty {
                emptyState
            } else if family == .systemSmall {
                smallLayout(entry.categories[0])
            } else {
                mediumLayout
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        // The app has no per-category route, so every tap lands on Budget.
        .widgetURL(URL(string: "actuali://budget"))
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.bar")
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

    private func smallLayout(_ category: WidgetCategoryBalance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Spacer(minLength: 0)
            // Next Bill's pattern: the name sits over its amount.
            Text(category.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(category.formattedSpent ?? "")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(String(
                format: String(localized: "of %@ budgeted", locale: locale),
                category.formattedBudgeted ?? ""
            ))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            HStack(spacing: 3) {
                // Truncate the label, never the amount, at large Dynamic Type.
                availableText(category)
                    .layoutPriority(1)
                Text(String(localized: "available"))
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
            .lineLimit(1)
            updatedFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityIdentifier("topSpendingWidget.categoryRow")
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isLargeFamily, let total = entry.formattedTotalSpending {
                totalSpentHeader(total)
            }
            // Drop trailing rows rather than clip them when Dynamic Type
            // leaves less height than the provider's row limit needs. Top
            // spenders win.
            ViewThatFits(in: .vertical) {
                ForEach((1...entry.categories.count).reversed(), id: \.self) { count in
                    categoryGrid(entry.categories.prefix(count))
                }
            }
            // Claim the height before the Spacer below, or the VStack splits
            // it between them and drops a row that fits.
            .layoutPriority(1)
            Spacer(minLength: 0)
            updatedFooter
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

    /// Same header as Recent Transactions. Black and unsigned, like the
    /// Spent column beneath it and Monthly Spending under budget.
    private func totalSpentHeader(_ total: String) -> some View {
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
        .accessibilityIdentifier("topSpendingWidget.totalSpent")
    }

    /// A grid so the amount columns line up whatever the name lengths.
    private func categoryGrid(_ categories: ArraySlice<WidgetCategoryBalance>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                // Large's header line is Monthly Spending; one icon header per widget.
                if isLargeFamily {
                    Text(String(localized: "Top Spending"))
                } else {
                    header
                }
                Text(String(localized: "Spent"))
                    .gridColumnAlignment(.trailing)
                Text(String(localized: "Available"))
                    .gridColumnAlignment(.trailing)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            ForEach(categories) { category in
                GridRow {
                    Text(category.name)
                        .font(.subheadline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("topSpendingWidget.categoryRow")
                    // Truncate the name, never an amount.
                    Text(category.formattedSpent ?? "")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    availableText(category)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }

    /// Category Balances' colours: red when overspent, green otherwise.
    /// Overspent adds a warning glyph, so it doesn't rest on color alone in
    /// tinted and clear modes. Hidden balances stay neutral so the mask
    /// doesn't leak the sign.
    private func availableText(_ category: WidgetCategoryBalance) -> some View {
        let overspent = category.isOverspent && !entry.balancesHidden
        return HStack(spacing: 2) {
            if overspent {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityLabel(String(localized: "Overspent"))
            }
            Text(category.formattedAvailable)
                .monospacedDigit()
        }
        .foregroundStyle(entry.balancesHidden ? Color.primary : overspent ? .red : .green)
    }

    private var header: some View {
        Label {
            Text(String(localized: "Top Spending"))
                .font(.caption.weight(.medium))
        } icon: {
            Image(systemName: "chart.bar")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var updatedFooter: some View {
        Text(String(
            format: String(localized: "Updated %@", locale: locale),
            WidgetDateFormatting.relative(entry.date, locale: locale)
        ))
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
}
