import AppIntents
import SwiftUI
import WidgetKit

struct CategoryBalanceWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "CategoryBalanceWidget",
            intent: SelectCategoriesIntent.self,
            provider: CategoryBalanceProvider()
        ) { entry in
            CategoryBalanceWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Category Balances"))
        .description(String(localized: "Remaining available amount for your chosen categories."))
        .supportedFamilies(WidgetFamily.systemFamilies())
    }
}

struct CategoryBalanceEntry: TimelineEntry {
    let date: Date
    let balancesHidden: Bool
    let categories: [WidgetCategoryBalance]
    let hasSnapshot: Bool

    static let sample = CategoryBalanceEntry(
        date: .now,
        balancesHidden: false,
        categories: [
            WidgetCategoryBalance(id: "dining", name: "Dining Out", available: 12350, formattedAvailable: "$123.50"),
            WidgetCategoryBalance(id: "groceries", name: "Groceries", available: 8020, formattedAvailable: "$80.20"),
            WidgetCategoryBalance(id: "fun", name: "Fun Money", available: -1550, formattedAvailable: "-$15.50"),
            WidgetCategoryBalance(id: "transport", name: "Transport", available: 4000, formattedAvailable: "$40.00"),
        ],
        hasSnapshot: true
    )
}

struct CategoryBalanceProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CategoryBalanceEntry {
        .sample
    }

    func snapshot(for configuration: SelectCategoriesIntent, in context: Context) async -> CategoryBalanceEntry {
        context.isPreview ? .sample : entry(for: configuration, in: context)
    }

    func timeline(for configuration: SelectCategoriesIntent, in context: Context) async -> Timeline<CategoryBalanceEntry> {
        // The app pushes reloads after every data refresh; the midnight
        // expiry only exists so a month rollover without an app launch
        // swaps stale balances for the empty state.
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        return Timeline(entries: [entry(for: configuration, in: context)], policy: .after(nextMidnight))
    }

    private func entry(for configuration: SelectCategoriesIntent, in context: Context) -> CategoryBalanceEntry {
        let limit = switch context.family {
        case .systemSmall: 1
        case .systemMedium: 4
        case .systemLarge: 8
        default: 12 // systemExtraLargePortrait; the case itself is iOS 27-only
        }
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              snapshot.isForMonth(containing: .now) else {
            return CategoryBalanceEntry(date: .now, balancesHidden: false, categories: [], hasSnapshot: false)
        }
        let chosenIds = (configuration.categories ?? []).map(\.id)
        return CategoryBalanceEntry(
            date: snapshot.generatedAt,
            balancesHidden: snapshot.balancesHidden,
            categories: snapshot.categories(matching: chosenIds, limit: limit),
            hasSnapshot: true
        )
    }
}

struct CategoryBalanceWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: CategoryBalanceEntry

    var body: some View {
        Group {
            if entry.categories.isEmpty {
                emptyState
            } else if family == .systemSmall {
                smallLayout(entry.categories[0])
            } else {
                listLayout
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "actuali://budget"))
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.pie")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(entry.hasSnapshot ? String(localized: "No categories to show") : String(localized: "Open Actuali to load your budget"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func smallLayout(_ category: WidgetCategoryBalance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(category.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(category.formattedAvailable)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(amountColor(for: category))
            Text(String(localized: "available"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Medium, large, and extra-large portrait share one single-column list;
    /// only the provider's row limit differs per family.
    private var listLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entry.categories) { category in
                if let rowIdentifier {
                    categoryRow(category).accessibilityIdentifier(rowIdentifier)
                } else {
                    categoryRow(category)
                }
            }
            Spacer(minLength: 0)
            WidgetUpdatedFooter(date: entry.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func categoryRow(_ category: WidgetCategoryBalance) -> some View {
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
                .foregroundStyle(amountColor(for: category))
        }
    }

    /// Medium rows stay untagged.
    private var rowIdentifier: String? {
        if family == .systemLarge {
            return "widgetLarge.categoryRow"
        }
        if family.isExtraLargePortrait {
            return "widgetExtraLarge.categoryRow"
        }
        return nil
    }

    /// Matches the Budget tab's row semantics: red when overspent, green
    /// otherwise — muted to neutral when balances are hidden so the mask
    /// doesn't leak the sign.
    private func amountColor(for category: WidgetCategoryBalance) -> Color {
        if entry.balancesHidden {
            return .primary
        }
        return category.isOverspent ? .red : .green
    }
}
