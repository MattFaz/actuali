import SwiftUI
import WidgetKit

struct SpendingComparisonWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "SpendingComparisonWidget",
            provider: SpendingComparisonProvider()
        ) { entry in
            SpendingComparisonWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Spending vs Last Month"))
        .description(String(localized: "How this month's spending compares with the same point last month."))
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

struct SpendingComparisonEntry: TimelineEntry {
    let date: Date
    let formattedThisMonth: String?
    let formattedLastMonth: String?
    /// nil leaves the widget to an empty state.
    let formattedDifference: String?
    let formattedPercentChange: String?
    /// Already nil when balances are hidden, so neither arrow nor red can
    /// leak the direction.
    let trend: WidgetSnapshot.SpendingTrend?
    let hasSnapshot: Bool
    /// Large and Extra Large Portrait only, biggest change first; each trend
    /// is already nil when balances are hidden. Defaulted so the Small and
    /// Medium entries don't have to spell it out.
    var movers: [(category: WidgetCategoryBalance, trend: WidgetSnapshot.SpendingTrend?)] = []

    static let sample = SpendingComparisonEntry(
        date: .now,
        formattedThisMonth: "$1,842.00",
        formattedLastMonth: "$1,600.00",
        formattedDifference: "$242.00",
        formattedPercentChange: "+15%",
        trend: .more,
        hasSnapshot: true,
        movers: [
            (WidgetCategoryBalance(
                id: "dining", name: "Dining Out", available: 0, formattedAvailable: "",
                spendingDifference: 18000, formattedSpendingDifference: "$180.00"
            ), .more),
            (WidgetCategoryBalance(
                id: "groceries", name: "Groceries", available: 0, formattedAvailable: "",
                spendingDifference: -6000, formattedSpendingDifference: "-$60.00"
            ), .less),
        ]
    )

    static let empty = SpendingComparisonEntry(
        date: .now, formattedThisMonth: nil, formattedLastMonth: nil, formattedDifference: nil,
        formattedPercentChange: nil, trend: nil, hasSnapshot: false
    )
}

struct SpendingComparisonProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpendingComparisonEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (SpendingComparisonEntry) -> Void) {
        completion(context.isPreview ? .sample : currentEntry())
    }

    /// Last month's side is month to date, so it moves at midnight even
    /// without new data; the app's write reloads it sooner.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SpendingComparisonEntry>) -> Void) {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [currentEntry()], policy: .after(nextMidnight)))
    }

    private func currentEntry() -> SpendingComparisonEntry {
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              snapshot.isForMonth(containing: .now) else {
            return .empty
        }
        return SpendingComparisonEntry(
            date: snapshot.generatedAt,
            formattedThisMonth: snapshot.formattedTotalSpending,
            formattedLastMonth: snapshot.formattedTotalSpendingLastMonth,
            formattedDifference: snapshot.formattedSpendingDifference,
            formattedPercentChange: snapshot.formattedSpendingPercentChange,
            trend: snapshot.spendingTrend,
            hasSnapshot: true,
            // The Extra Large Portrait count; Large shows the first.
            movers: snapshot.categoryMovers(limit: 4).map { ($0, snapshot.spendingTrend(of: $0)) }
        )
    }
}

struct SpendingComparisonWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.locale) private var locale

    let entry: SpendingComparisonEntry

    var body: some View {
        Group {
            if let difference = entry.formattedDifference {
                if family == .systemSmall {
                    smallLayout(difference)
                } else if isLargeFamily {
                    largeLayout(difference)
                } else {
                    mediumLayout(difference)
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
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(entry.hasSnapshot
                ? String(localized: "Nothing from last month to compare yet")
                : String(localized: "Open Actuali to load your budget"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func smallLayout(_ difference: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Spacer(minLength: 0)
            differenceAmount(difference, font: .title2.weight(.semibold))
            if let percent {
                Text(percent)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(trendLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            updatedFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityIdentifier("spendingComparisonWidget.difference")
    }

    private func mediumLayout(_ difference: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            comparisonColumns(difference)
            Spacer(minLength: 0)
            updatedFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Large: the comparison plus the top mover. Extra Large Portrait lists
    /// up to four movers. Rows pin to the top, leaving any spare height above
    /// the footer.
    private func largeLayout(_ difference: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            comparisonColumns(difference)
            VStack(alignment: .leading, spacing: 6) {
                Text(isExtraLargePortrait ? String(localized: "Biggest changes") : String(localized: "Top mover"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if entry.movers.isEmpty {
                    Text(String(localized: "No category has changed since last month"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    ForEach(entry.movers.prefix(isExtraLargePortrait ? 4 : 1), id: \.category.id) { mover in
                        moverRow(mover.category, trend: mover.trend)
                    }
                }
            }
            Spacer(minLength: 0)
            updatedFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var isLargeFamily: Bool {
        family == .systemLarge || isExtraLargePortrait
    }

    /// `systemExtraLargePortrait` is iOS 27-only, so it's matched behind
    /// `#available` rather than a `switch` case.
    private var isExtraLargePortrait: Bool {
        if #available(iOS 27.0, *) {
            return family == .systemExtraLargePortrait
        }
        return false
    }

    private func comparisonColumns(_ difference: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            column(
                amount: Text(entry.formattedThisMonth ?? "—").font(.title3.weight(.semibold)),
                label: String(localized: "This month so far"),
                identifier: "spendingComparisonWidget.thisMonth"
            )
            column(
                amount: Text(entry.formattedLastMonth ?? "—").font(.title3.weight(.semibold)),
                label: String(localized: "Same time last month"),
                identifier: "spendingComparisonWidget.lastMonth"
            )
            column(
                amount: differenceAmount(difference, font: .title3.weight(.semibold)),
                label: [percent, trendLabel].compactMap(\.self).joined(separator: " · "),
                identifier: "spendingComparisonWidget.difference"
            )
        }
    }

    /// Same colour rule and glyphs as the headline difference; the trend
    /// words ride along for VoiceOver, where the glyph is hidden.
    private func moverRow(_ category: WidgetCategoryBalance, trend: WidgetSnapshot.SpendingTrend?) -> some View {
        HStack {
            Text(category.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            // Truncate the name, never the amount.
            HStack(spacing: 3) {
                if let glyph = Self.glyph(for: trend) {
                    Image(systemName: glyph)
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                Text(category.formattedSpendingDifference ?? "—")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(trend == .more ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Self.trendLabel(for: trend))
        .accessibilityIdentifier("spendingComparisonWidget.mover.\(category.id)")
    }

    /// Small drops "Spending", which otherwise truncates at default text size.
    private var header: some View {
        Label {
            Text(family == .systemSmall ? String(localized: "vs Last Month") : String(localized: "Spending vs Last Month"))
                .font(.caption.weight(.medium))
        } icon: {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// trend is nil only when hidden here (no last-month data is the empty
    /// state), and a second mask beside the amount's adds nothing.
    private var percent: String? {
        entry.trend == nil ? nil : entry.formattedPercentChange
    }

    /// The words carry the direction, so it doesn't rest on the arrow or red
    /// in tinted and clear modes. Hidden balances get the neutral wording.
    private var trendLabel: String {
        Self.trendLabel(for: entry.trend)
    }

    private static func trendLabel(for trend: WidgetSnapshot.SpendingTrend?) -> String {
        switch trend {
        case .more: String(localized: "More than last month")
        case .less: String(localized: "Less than last month")
        case .same: String(localized: "Same as last month")
        case nil: String(localized: "vs last month")
        }
    }

    /// Red marks an increase — the one non-overspent red the widget design
    /// standard allows. A decrease stays primary rather than green, keeping
    /// the colour for the case worth noticing.
    private func differenceAmount(_ difference: String, font: Font) -> some View {
        HStack(spacing: 3) {
            if let glyph = Self.glyph(for: entry.trend) {
                Image(systemName: glyph)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(difference)
                .font(font)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .foregroundStyle(entry.trend == .more ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
    }

    private static func glyph(for trend: WidgetSnapshot.SpendingTrend?) -> String? {
        switch trend {
        case .more: "arrow.up"
        case .less: "arrow.down"
        case .same: "equal"
        case nil: nil
        }
    }

    private func column(amount: some View, label: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            amount
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            // The label is what makes the number mean anything, so it keeps
            // both lines at large Dynamic Type and the amount scales instead.
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
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
