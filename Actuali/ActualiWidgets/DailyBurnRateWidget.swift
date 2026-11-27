import SwiftUI
import WidgetKit

struct DailyBurnRateWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "DailyBurnRateWidget",
            provider: DailyBurnRateProvider()
        ) { entry in
            DailyBurnRateWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Daily Burn Rate"))
        .description(String(localized: "What you spend per day this month, and what you can still spend."))
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

struct DailyBurnRateEntry: TimelineEntry {
    let date: Date
    /// nil leaves the widget to its empty state.
    let formattedAverageSpendPerDay: String?
    /// nil when nothing is budgeted this month.
    let formattedSafeDailyRate: String?
    /// Already false when balances are hidden, so the red can't leak the sign.
    let isOverbudget: Bool
    /// Large and Extra Large Portrait only; defaulted so the Small and Medium
    /// entries don't have to spell them out.
    var formattedProjectedSpending: String?
    var formattedAverageSpendPerWeek: String?
    var formattedSafeWeeklyRate: String?
    var daysElapsed: Int?
    var daysRemaining: Int?
    var monthProgress: Double?

    static let sample = DailyBurnRateEntry(
        date: .now,
        formattedAverageSpendPerDay: "$42.10",
        formattedSafeDailyRate: "$38.75",
        isOverbudget: false,
        formattedProjectedSpending: "$1,263.00",
        formattedAverageSpendPerWeek: "$294.70",
        formattedSafeWeeklyRate: "$271.25",
        daysElapsed: 10,
        daysRemaining: 21,
        monthProgress: 10.0 / 30
    )
}

struct DailyBurnRateProvider: TimelineProvider {
    func placeholder(in context: Context) -> DailyBurnRateEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (DailyBurnRateEntry) -> Void) {
        completion(context.isPreview ? .sample : currentEntry())
    }

    /// Both rates divide by today's day number, so they go stale at midnight
    /// even without new data; the app's write reloads them sooner.
    func getTimeline(in context: Context, completion: @escaping (Timeline<DailyBurnRateEntry>) -> Void) {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [currentEntry()], policy: .after(nextMidnight)))
    }

    private func currentEntry() -> DailyBurnRateEntry {
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              snapshot.isForMonth(containing: .now) else {
            return DailyBurnRateEntry(date: .now, formattedAverageSpendPerDay: nil, formattedSafeDailyRate: nil, isOverbudget: false)
        }
        return DailyBurnRateEntry(
            date: snapshot.generatedAt,
            formattedAverageSpendPerDay: snapshot.formattedAverageSpendPerDay,
            formattedSafeDailyRate: snapshot.formattedSafeDailyRate,
            isOverbudget: snapshot.isOverbudget,
            formattedProjectedSpending: snapshot.formattedProjectedSpending,
            formattedAverageSpendPerWeek: snapshot.formattedAverageSpendPerWeek,
            formattedSafeWeeklyRate: snapshot.formattedSafeWeeklyRate,
            daysElapsed: snapshot.daysElapsed,
            daysRemaining: snapshot.daysRemaining,
            monthProgress: snapshot.monthProgress
        )
    }
}

struct DailyBurnRateWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.locale) private var locale

    let entry: DailyBurnRateEntry

    var body: some View {
        Group {
            if let average = entry.formattedAverageSpendPerDay {
                if family == .systemSmall {
                    smallLayout(average)
                } else if isLargeFamily {
                    largeLayout(average)
                } else {
                    mediumLayout(average)
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
            Image(systemName: "flame")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(String(localized: "Open Actuali to load your budget"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func smallLayout(_ average: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Spacer(minLength: 0)
            Text(average)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityIdentifier("dailyBurnRateWidget.average")
            Text(String(localized: "per day so far"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            updatedFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func mediumLayout(_ average: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            dailyRates(average)
            Spacer(minLength: 0)
            updatedFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Large: the daily rates, days left and the projected month. Extra Large
    /// Portrait swaps the projection for the rates per week and the month's
    /// progress. Rows pin to the top, leaving any spare height above the footer.
    private func largeLayout(_ average: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            dailyRates(average)
            if isExtraLargePortrait {
                ratePair(
                    entry.formattedAverageSpendPerWeek ?? "—",
                    spentLabel: String(localized: "Spent per week so far"),
                    safe: entry.formattedSafeWeeklyRate,
                    safeLabel: String(localized: "Safe to spend per week"),
                    identifiers: ("dailyBurnRateWidget.weeklyAverage", "dailyBurnRateWidget.weeklySafeRate")
                )
            }
            VStack(alignment: .leading, spacing: 6) {
                if let daysRemaining = entry.daysRemaining {
                    statRow(String(localized: "Days left"), value: Text(daysRemaining, format: .number))
                        .accessibilityIdentifier("dailyBurnRateWidget.daysLeft")
                }
                if !isExtraLargePortrait, let projected = entry.formattedProjectedSpending {
                    statRow(String(localized: "Projected this month"), value: Text(projected))
                        .accessibilityIdentifier("dailyBurnRateWidget.projected")
                }
            }
            if isExtraLargePortrait, let progress = entry.monthProgress,
               let elapsed = entry.daysElapsed, let remaining = entry.daysRemaining {
                // Monthly Spending's bar rather than ProgressView, so every
                // bar in the suite has the same height, track and ends.
                VStack(alignment: .leading, spacing: 2) {
                    statRow(String(localized: "Month progress"), value: Text(String(
                        format: String(localized: "Day %1$lld of %2$lld", locale: locale),
                        elapsed, elapsed + remaining - 1
                    )))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 6)
                            Capsule()
                                .fill(.blue)
                                .frame(width: geo.size.width * min(max(progress, 0), 1), height: 6)
                        }
                    }
                    .frame(height: 6)
                    .padding(.vertical, 2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("dailyBurnRateWidget.monthProgress")
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

    private func dailyRates(_ average: String) -> some View {
        ratePair(
            average,
            spentLabel: String(localized: "Spent per day so far"),
            safe: entry.formattedSafeDailyRate,
            safeLabel: String(localized: "Safe to spend per day"),
            identifiers: ("dailyBurnRateWidget.average", "dailyBurnRateWidget.safeRate")
        )
    }

    /// Over budget swaps the safe label's text and adds a glyph, so it doesn't
    /// rest on the red alone in tinted and clear modes.
    private func ratePair(
        _ spent: String, spentLabel: String, safe: String?, safeLabel: String, identifiers: (spent: String, safe: String)
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            rate(spent, label: spentLabel, identifier: identifiers.spent)
            if let safe {
                rate(
                    safe,
                    label: entry.isOverbudget ? String(localized: "Over budget") : safeLabel,
                    identifier: identifiers.safe,
                    overspent: entry.isOverbudget
                )
            } else {
                rate("—", label: String(localized: "Nothing budgeted"), identifier: identifiers.safe)
            }
        }
    }

    private func statRow(_ label: String, value: Text) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            // Truncate the label, never the value.
            value
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        Label {
            Text(String(localized: "Daily Burn Rate"))
                .font(.caption.weight(.medium))
        } icon: {
            Image(systemName: "flame")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func rate(_ amount: String, label: String, identifier: String, overspent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                if overspent {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .accessibilityHidden(true)
                }
                Text(amount)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .foregroundStyle(overspent ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
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
