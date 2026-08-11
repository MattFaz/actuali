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
        .configurationDisplayName("Category Balances")
        .description("Remaining available amount for your chosen categories.")
        .supportedFamilies([.systemSmall, .systemMedium])
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
            WidgetCategoryBalance(id: "dining", name: "Dining Out", available: 12_350, formattedAvailable: "$123.50"),
            WidgetCategoryBalance(id: "groceries", name: "Groceries", available: 8_020, formattedAvailable: "$80.20"),
            WidgetCategoryBalance(id: "fun", name: "Fun Money", available: -1_550, formattedAvailable: "-$15.50"),
            WidgetCategoryBalance(id: "transport", name: "Transport", available: 4_000, formattedAvailable: "$40.00"),
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
        // The app calls WidgetCenter.reloadAllTimelines() after every data
        // refresh (foreground, pull-to-refresh, background sync), so the
        // timeline itself never needs to expire.
        Timeline(entries: [entry(for: configuration, in: context)], policy: .never)
    }

    private func entry(for configuration: SelectCategoriesIntent, in context: Context) -> CategoryBalanceEntry {
        let limit = context.family == .systemSmall ? 1 : 4
        guard let snapshot = WidgetSnapshotStore.standard()?.read() else {
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
                mediumLayout
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.pie")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(entry.hasSnapshot ? "No categories to show" : "Open Actuali to load your budget")
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
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(amountColor(for: category))
            Text("available")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entry.categories) { category in
                HStack {
                    Text(category.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(category.formattedAvailable)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(amountColor(for: category))
                }
            }
            Spacer(minLength: 0)
            Text("Updated \(entry.date, style: .relative) ago")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Matches the Budget tab's row semantics: red when overspent, green
    /// otherwise — muted to neutral when balances are hidden so the mask
    /// doesn't leak the sign.
    private func amountColor(for category: WidgetCategoryBalance) -> Color {
        if entry.balancesHidden { return .primary }
        return category.isOverspent ? .red : .green
    }
}
