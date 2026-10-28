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
        .supportedFamilies([
            .systemSmall,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

struct ToBeBudgetedEntry: TimelineEntry {
    let date: Date
    let balancesHidden: Bool
    let toBudget: Int?
    let formattedToBudget: String?
    let hasSnapshot: Bool
    /// nil when the snapshot has no toBudget (tracking budget).
    let isTrackingBudget: Bool

    static let sample = ToBeBudgetedEntry(
        date: .now,
        balancesHidden: false,
        toBudget: 52340,
        formattedToBudget: "$523.40",
        hasSnapshot: true,
        isTrackingBudget: false
    )
}

struct ToBeBudgetedProvider: TimelineProvider {
    func placeholder(in context: Context) -> ToBeBudgetedEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (ToBeBudgetedEntry) -> Void) {
        completion(context.isPreview ? .sample : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ToBeBudgetedEntry>) -> Void) {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [currentEntry()], policy: .after(nextMidnight)))
    }

    private func currentEntry() -> ToBeBudgetedEntry {
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              snapshot.isForMonth(containing: .now) else {
            return ToBeBudgetedEntry(date: .now, balancesHidden: false, toBudget: nil, formattedToBudget: nil, hasSnapshot: false, isTrackingBudget: false)
        }
        return ToBeBudgetedEntry(
            date: snapshot.generatedAt,
            balancesHidden: snapshot.balancesHidden,
            toBudget: snapshot.toBudget,
            formattedToBudget: snapshot.formattedToBudget,
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
            switch family {
            case .accessoryCircular:
                circularLayout
            case .accessoryRectangular:
                rectangularLayout
            case .accessoryInline:
                inlineLayout
            default:
                smallLayout
                    .containerBackground(.fill.tertiary, for: .widget)
            }
        }
        .widgetURL(URL(string: "actuali://budget"))
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "tray.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let formatted = entry.formattedToBudget {
                Text(formatted)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .foregroundStyle(tbbColor)
            } else if entry.isTrackingBudget {
                Text(String(localized: "Tracking Budget"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(entry.hasSnapshot
                    ? String(localized: "—")
                    : String(localized: "Open Actuali"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(String(
                format: String(localized: "Updated %@", locale: locale),
                WidgetDateFormatting.relative(entry.date, locale: locale)
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Lock Screen

    private var circularLayout: some View {
        VStack(spacing: 1) {
            Image(systemName: "tray.and.arrow.down")
                .font(.caption)
            if let formatted = entry.formattedToBudget {
                Text(formatted)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
            } else {
                Text("—")
                    .font(.caption)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var rectangularLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let formatted = entry.formattedToBudget {
                Text(formatted)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else {
                Text(entry.isTrackingBudget
                    ? String(localized: "Tracking Budget")
                    : String(localized: "Open Actuali"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var inlineLayout: some View {
        Group {
            if let formatted = entry.formattedToBudget {
                Text(verbatim: "\(label): \(formatted)")
            } else {
                Text(verbatim: "\(label): —")
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var label: String {
        guard let toBudget = entry.toBudget else {
            return String(localized: "To Budget")
        }
        return toBudget < 0
            ? String(localized: "Overbudgeted")
            : String(localized: "To Budget")
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
