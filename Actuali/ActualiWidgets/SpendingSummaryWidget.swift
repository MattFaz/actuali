import SwiftUI
import WidgetKit

struct SpendingSummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "SpendingSummaryWidget",
            provider: SpendingSummaryProvider()
        ) { entry in
            SpendingSummaryWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Monthly Spending"))
        .description(String(localized: "Summary of your spending versus budgeted amount this month."))
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

struct SpendingSummaryEntry: TimelineEntry {
    let date: Date
    let balancesHidden: Bool
    let spentFraction: Double
    let isOverbudget: Bool
    let formattedTotalSpent: String?
    let formattedTotalBudgeted: String?
    let formattedTotalIncome: String?
    /// The budget's first categories in budget order, capped per family.
    let categories: [WidgetCategoryBalance]
    let hasSnapshot: Bool

    static let sample = SpendingSummaryEntry(
        date: .now,
        balancesHidden: false,
        spentFraction: 184_200 / 320_000,
        isOverbudget: false,
        formattedTotalSpent: "$1,842.00",
        formattedTotalBudgeted: "$3,200.00",
        formattedTotalIncome: "$4,500.00",
        categories: CategoryBalanceEntry.sample.categories,
        hasSnapshot: true
    )
}

struct SpendingSummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpendingSummaryEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (SpendingSummaryEntry) -> Void) {
        completion(context.isPreview ? .sample : currentEntry(for: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpendingSummaryEntry>) -> Void) {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [currentEntry(for: context.family)], policy: .after(nextMidnight)))
    }

    private func currentEntry(for family: WidgetFamily) -> SpendingSummaryEntry {
        // Small and Medium show totals only.
        let limit = switch family {
        case .systemSmall, .systemMedium: 0
        case .systemLarge: 5
        default: 8 // systemExtraLargePortrait; the case itself is iOS 27-only
        }
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              snapshot.isForMonth(containing: .now) else {
            return SpendingSummaryEntry(
                date: .now,
                balancesHidden: false,
                spentFraction: 0,
                isOverbudget: false,
                formattedTotalSpent: nil,
                formattedTotalBudgeted: nil,
                formattedTotalIncome: nil,
                categories: [],
                hasSnapshot: false
            )
        }
        return SpendingSummaryEntry(
            date: snapshot.generatedAt,
            balancesHidden: snapshot.balancesHidden,
            spentFraction: snapshot.spentFraction,
            isOverbudget: snapshot.isOverbudget,
            formattedTotalSpent: snapshot.formattedTotalSpent,
            formattedTotalBudgeted: snapshot.formattedTotalBudgeted,
            formattedTotalIncome: snapshot.formattedTotalIncome,
            categories: snapshot.categories(matching: [], limit: limit),
            hasSnapshot: true
        )
    }
}

struct SpendingSummaryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.locale) private var locale

    let entry: SpendingSummaryEntry

    var body: some View {
        Group {
            if !entry.hasSnapshot {
                emptyState
            } else if family == .systemSmall {
                smallLayout
            } else if showsCategoryList {
                listLayout
            } else {
                mediumLayout
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "actuali://budget"))
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "creditcard")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(String(localized: "Open Actuali to load your budget"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(String(localized: "Spending"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "creditcard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(entry.formattedTotalSpent ?? "—")
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .foregroundStyle(spendingColor)

            if let formattedBudget = entry.formattedTotalBudgeted {
                progressBar(height: 5)

                Text(String(
                    format: String(localized: "of %@ budgeted", locale: locale),
                    formattedBudget
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else {
                Text(String(localized: "This Month"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumLayout: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(String(localized: "Monthly Spending"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "creditcard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(entry.formattedTotalSpent ?? "—")
                    .font(.title.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(spendingColor)

                if let formattedBudget = entry.formattedTotalBudgeted {
                    progressBar(height: 6)

                    Text(String(
                        format: String(localized: "of %@ budgeted", locale: locale),
                        formattedBudget
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(String(
                    format: String(localized: "Updated %@", locale: locale),
                    WidgetDateFormatting.relative(entry.date, locale: locale)
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                if let income = entry.formattedTotalIncome {
                    statBlock(title: String(localized: "Income"), value: income, color: .green)
                }
                if let budgeted = entry.formattedTotalBudgeted {
                    statBlock(title: String(localized: "Budgeted"), value: budgeted, color: .primary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `systemExtraLargePortrait` is iOS 27-only, so it's matched behind
    /// `#available` rather than a `switch` case.
    private var showsCategoryList: Bool {
        if family == .systemLarge {
            return true
        }
        if #available(iOS 27.0, *), family == .systemExtraLargePortrait {
            return true
        }
        return false
    }

    /// Large and Extra Large Portrait: Medium's spent/budgeted progress at the
    /// top, then the provider's category rows; only the row limit differs.
    private var listLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            Text(entry.formattedTotalSpent ?? "—")
                .font(.title.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(spendingColor)
                .accessibilityIdentifier("spendingSummaryWidget.spent")
            if let formattedBudget = entry.formattedTotalBudgeted {
                progressBar(height: 6)
                Text(String(
                    format: String(localized: "of %@ budgeted", locale: locale),
                    formattedBudget
                ))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("spendingSummaryWidget.budgeted")
            }
            if entry.categories.isEmpty {
                Text(String(localized: "No categories to show"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(entry.categories) { category in
                categoryRow(category)
                    .accessibilityIdentifier("spendingSummaryWidget.categoryRow")
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
                .foregroundStyle(availableColor(for: category))
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

    private func progressBar(height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: height)
                Capsule()
                    .fill(progressColor)
                    .frame(width: geo.size.width * entry.spentFraction, height: height)
            }
        }
        .frame(height: height)
        .padding(.vertical, 2)
    }

    private func statBlock(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(entry.balancesHidden ? .primary : color)
        }
    }

    private var spendingColor: Color {
        if entry.balancesHidden {
            return .primary
        }
        return entry.isOverbudget ? .red : .primary
    }

    private var progressColor: Color {
        if entry.balancesHidden {
            return .primary
        }
        return entry.isOverbudget ? .red : .blue
    }
}
