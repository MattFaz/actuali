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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SpendingSummaryEntry: TimelineEntry {
    let date: Date
    let balancesHidden: Bool
    let totalSpent: Int?
    let formattedTotalSpent: String?
    let totalBudgeted: Int?
    let formattedTotalBudgeted: String?
    let totalIncome: Int?
    let formattedTotalIncome: String?
    let hasSnapshot: Bool

    static let sample = SpendingSummaryEntry(
        date: .now,
        balancesHidden: false,
        totalSpent: -184_200,
        formattedTotalSpent: "$1,842.00",
        totalBudgeted: 320_000,
        formattedTotalBudgeted: "$3,200.00",
        totalIncome: 450_000,
        formattedTotalIncome: "$4,500.00",
        hasSnapshot: true
    )
}

struct SpendingSummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpendingSummaryEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (SpendingSummaryEntry) -> Void) {
        completion(context.isPreview ? .sample : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpendingSummaryEntry>) -> Void) {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [currentEntry()], policy: .after(nextMidnight)))
    }

    private func currentEntry() -> SpendingSummaryEntry {
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              snapshot.isForMonth(containing: .now) else {
            return SpendingSummaryEntry(
                date: .now,
                balancesHidden: false,
                totalSpent: nil,
                formattedTotalSpent: nil,
                totalBudgeted: nil,
                formattedTotalBudgeted: nil,
                totalIncome: nil,
                formattedTotalIncome: nil,
                hasSnapshot: false
            )
        }
        return SpendingSummaryEntry(
            date: snapshot.generatedAt,
            balancesHidden: snapshot.balancesHidden,
            totalSpent: snapshot.totalSpent,
            formattedTotalSpent: snapshot.formattedTotalSpent,
            totalBudgeted: snapshot.totalBudgeted,
            formattedTotalBudgeted: snapshot.formattedTotalBudgeted,
            totalIncome: snapshot.totalIncome,
            formattedTotalIncome: snapshot.formattedTotalIncome,
            hasSnapshot: true
        )
    }
}

struct SpendingSummaryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.locale) private var locale

    let entry: SpendingSummaryEntry

    private var spentFraction: Double {
        guard let spent = entry.totalSpent, let budgeted = entry.totalBudgeted, budgeted > 0 else {
            return 0
        }
        return min(max(Double(abs(spent)) / Double(budgeted), 0.0), 1.0)
    }

    private var isOverbudget: Bool {
        guard let spent = entry.totalSpent, let budgeted = entry.totalBudgeted, budgeted > 0 else {
            return false
        }
        return abs(spent) > budgeted
    }

    var body: some View {
        Group {
            if !entry.hasSnapshot {
                emptyState
            } else if family == .systemSmall {
                smallLayout
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
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 5)
                        Capsule()
                            .fill(progressColor)
                            .frame(width: geo.size.width * spentFraction, height: 5)
                    }
                }
                .frame(height: 5)
                .padding(.vertical, 2)

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
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 6)
                            Capsule()
                                .fill(progressColor)
                                .frame(width: geo.size.width * spentFraction, height: 6)
                        }
                    }
                    .frame(height: 6)
                    .padding(.vertical, 2)

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
        return isOverbudget ? .red : .primary
    }

    private var progressColor: Color {
        if entry.balancesHidden {
            return .primary
        }
        return isOverbudget ? .red : .blue
    }
}
