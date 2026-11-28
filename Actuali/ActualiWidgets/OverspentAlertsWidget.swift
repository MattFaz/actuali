import SwiftUI
import WidgetKit

struct OverspentAlertsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "OverspentAlertsWidget",
            provider: OverspentAlertsProvider()
        ) { entry in
            OverspentAlertsWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Overspent Alerts"))
        .description(String(localized: "Categories you've overspent this month."))
        .supportedFamilies(WidgetFamily.systemFamilies())
    }
}

struct OverspentAlertsEntry: TimelineEntry {
    let date: Date
    /// When true the rows are every category in budget order rather than
    /// just the overspent ones (see overspentCategories), so the widget
    /// stops calling them overspent.
    let balancesHidden: Bool
    /// Uncapped: Small shows the count, the larger families the first few.
    let categories: [WidgetCategoryBalance]
    let hasSnapshot: Bool

    static let sample = OverspentAlertsEntry(
        date: .now,
        balancesHidden: false,
        categories: [
            WidgetCategoryBalance(
                id: "dining", name: "Dining Out", available: -1550, formattedAvailable: "-$15.50",
                budgeted: 20000, spent: -21550, formattedSpent: "$215.50", formattedBudgeted: "$200.00"
            ),
            WidgetCategoryBalance(
                id: "gas", name: "Gas", available: -820, formattedAvailable: "-$8.20",
                budgeted: 10000, spent: -10820, formattedSpent: "$108.20", formattedBudgeted: "$100.00"
            ),
        ],
        hasSnapshot: true
    )
}

struct OverspentAlertsProvider: TimelineProvider {
    func placeholder(in context: Context) -> OverspentAlertsEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (OverspentAlertsEntry) -> Void) {
        completion(context.isPreview ? .sample : currentEntry())
    }

    /// Balances are this month's, so they go stale when the month rolls
    /// over even without new data; the app's write reloads it sooner.
    func getTimeline(in context: Context, completion: @escaping (Timeline<OverspentAlertsEntry>) -> Void) {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [currentEntry()], policy: .after(nextMidnight)))
    }

    private func currentEntry() -> OverspentAlertsEntry {
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              snapshot.isForMonth(containing: .now) else {
            return OverspentAlertsEntry(date: .now, balancesHidden: false, categories: [], hasSnapshot: false)
        }
        return OverspentAlertsEntry(
            date: snapshot.generatedAt,
            balancesHidden: snapshot.balancesHidden,
            categories: snapshot.overspentCategories,
            hasSnapshot: true
        )
    }
}

struct OverspentAlertsWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: OverspentAlertsEntry

    /// The width Large keeps for a name before it gives up the Budgeted
    /// column; scaled so it holds a few characters at any text size.
    @ScaledMetric(relativeTo: .subheadline) private var largeNameWidth: CGFloat = 96

    var body: some View {
        Group {
            if let first = entry.categories.first {
                if let limit = largeFamilyLimit {
                    largeLayout(limit: limit)
                } else if family != .systemSmall {
                    mediumLayout
                } else if entry.balancesHidden {
                    hiddenSmallLayout(first)
                } else {
                    smallLayout(first)
                }
            } else {
                emptyState
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        // The app has no per-category route, so every tap lands on Budget.
        .widgetURL(URL(string: "actuali://budget"))
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: entry.hasSnapshot ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(entry.hasSnapshot
                ? String(localized: "Nothing overspent this month")
                : String(localized: "Open Actuali to load your budget"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// The count leads; the worst category under it says where to look.
    private func smallLayout(_ worst: WidgetCategoryBalance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                header
                Spacer(minLength: 0)
                Text(entry.categories.count, format: .number)
                    .font(.largeTitle.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("overspentAlertsWidget.count")
            VStack(alignment: .leading, spacing: 1) {
                Text(worst.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                availableText(worst)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("overspentAlertsWidget.categoryRow")
            Spacer(minLength: 0)
            WidgetUpdatedFooter(date: entry.date)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// A count would reveal how many categories are overspent, so hidden
    /// balances get the first category in budget order with its masked
    /// amount, as Top Spending does.
    private func hiddenSmallLayout(_ category: WidgetCategoryBalance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                availableText(category)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("overspentAlertsWidget.categoryRow")
            Spacer(minLength: 0)
            WidgetUpdatedFooter(date: entry.date)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumLayout: some View {
        let shown = entry.categories.prefix(WidgetRowLimits.overspentAlerts.medium)
        return VStack(alignment: .leading, spacing: 4) {
            // Drop trailing rows rather than clip them when Dynamic Type
            // leaves less height than four rows need. The worst wins.
            ViewThatFits(in: .vertical) {
                ForEach((1...shown.count).reversed(), id: \.self) { count in
                    categoryGrid(shown.prefix(count))
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

    /// A grid so the amounts line up whatever the name lengths; the title
    /// rides in the column-header row to leave height for four rows. No
    /// Spent column: beside Available it overruns Medium's width at large
    /// Dynamic Type, and the overspend is the number that matters here.
    private func categoryGrid(_ categories: ArraySlice<WidgetCategoryBalance>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            GridRow {
                header
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
                    // Truncate the name, never the amount.
                    availableText(category)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("overspentAlertsWidget.categoryRow")
            }
        }
    }

    /// Large and Extra Large Portrait: rows pinned to the top, leaving any
    /// spare height above the footer as Category Balances does.
    private func largeLayout(limit: Int) -> some View {
        let shown = entry.categories.prefix(limit)
        return VStack(alignment: .leading, spacing: 4) {
            // Drop Budgeted before the names shrink to nothing at large text
            // sizes, and drop trailing rows rather than clip them when Dynamic
            // Type (the widget cap is XXX Large) leaves less height than the
            // limit needs. The worst wins.
            ViewThatFits(in: .horizontal) {
                ForEach([true, false], id: \.self) { showsBudgeted in
                    ViewThatFits(in: .vertical) {
                        ForEach((1...shown.count).reversed(), id: \.self) { count in
                            largeGrid(shown.prefix(count), showsBudgeted: showsBudgeted)
                        }
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            WidgetUpdatedFooter(date: entry.date)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Large's width fits Budgeted beside Available, so the overspend reads
    /// against what was planned.
    private func largeGrid(_ categories: ArraySlice<WidgetCategoryBalance>, showsBudgeted: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                header
                if showsBudgeted {
                    Text(String(localized: "Budgeted"))
                        .gridColumnAlignment(.trailing)
                }
                Text(String(localized: "Available"))
                    .gridColumnAlignment(.trailing)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            ForEach(categories) { category in
                GridRow {
                    // The ideal width is what ViewThatFits measures against, so
                    // a long name can't by itself push Budgeted out.
                    Text(category.name)
                        .font(.subheadline)
                        .lineLimit(1)
                        .frame(minWidth: 0, idealWidth: largeNameWidth, maxWidth: .infinity, alignment: .leading)
                    // Truncate the name, never the amounts.
                    if showsBudgeted {
                        Text(category.formattedBudgeted ?? "")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    availableText(category)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("overspentAlertsWidget.categoryRow")
            }
        }
    }

    /// Large and Extra Large Portrait's row cap, nil for the smaller families.
    private var largeFamilyLimit: Int? {
        family.isLarge ? WidgetRowLimits.overspentAlerts.rows(for: family) : nil
    }

    /// Hidden rows are every category, not the overspent ones, so the title
    /// stops calling them overspent.
    private var header: some View {
        Label {
            Text(entry.balancesHidden ? String(localized: "Categories") : String(localized: "Overspent"))
                .font(.caption.weight(.medium))
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// Overspent reads red with a warning glyph, so it doesn't rest on color
    /// alone in tinted and clear modes. Hidden balances stay neutral so the
    /// mask doesn't leak the sign.
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
        .foregroundStyle(overspent ? Color.red : .primary)
    }
}
