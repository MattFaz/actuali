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
    @Environment(\.locale) private var locale

    let entry: ToBeBudgetedEntry

    var body: some View {
        AccessoryAmountView(
            icon: "tray.and.arrow.down",
            label: label,
            value: entry.formattedToBudget,
            placeholder: entry.isTrackingBudget
                ? String(localized: "Tracking Budget")
                : (entry.hasSnapshot ? String(localized: "—") : String(localized: "Open Actuali to load your budget")),
            inlineFormat: inlineFormat,
            color: tbbColor,
            updateDate: entry.date,
            locale: locale
        )
        .widgetURL(URL(string: "actuali://budget"))
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
