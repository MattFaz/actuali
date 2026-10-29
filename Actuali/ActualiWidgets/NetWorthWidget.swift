import SwiftUI
import WidgetKit

struct NetWorthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "NetWorthWidget",
            provider: NetWorthProvider()
        ) { entry in
            NetWorthWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Net Worth"))
        .description(String(localized: "Total balance across all your accounts."))
        .supportedFamilies([
            .systemSmall,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

struct NetWorthEntry: TimelineEntry {
    let date: Date
    let balancesHidden: Bool
    let netWorth: Int?
    let formattedNetWorth: String?
    let hasSnapshot: Bool

    static let sample = NetWorthEntry(
        date: .now,
        balancesHidden: false,
        netWorth: 4_903_150,
        formattedNetWorth: "$49,031.50",
        hasSnapshot: true
    )
}

struct NetWorthProvider: TimelineProvider {
    func placeholder(in context: Context) -> NetWorthEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (NetWorthEntry) -> Void) {
        completion(context.isPreview ? .sample : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NetWorthEntry>) -> Void) {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [currentEntry()], policy: .after(nextMidnight)))
    }

    private func currentEntry() -> NetWorthEntry {
        guard let snapshot = WidgetSnapshotStore.standard()?.read() else {
            return NetWorthEntry(date: .now, balancesHidden: false, netWorth: nil, formattedNetWorth: nil, hasSnapshot: false)
        }
        return NetWorthEntry(
            date: snapshot.generatedAt,
            balancesHidden: snapshot.balancesHidden,
            netWorth: snapshot.netWorth,
            formattedNetWorth: snapshot.formattedNetWorth,
            hasSnapshot: true
        )
    }
}

struct NetWorthWidgetView: View {
    @Environment(\.locale) private var locale

    let entry: NetWorthEntry

    var body: some View {
        AccessoryAmountView(
            icon: "chart.line.uptrend.xyaxis",
            label: String(localized: "Net Worth"),
            value: entry.formattedNetWorth,
            placeholder: entry.hasSnapshot ? String(localized: "—") : String(localized: "Open Actuali to load your budget"),
            inlineFormat: String(localized: "Net Worth: %@", locale: locale),
            color: netWorthColor,
            updateDate: entry.date,
            locale: locale
        )
        .widgetURL(URL(string: "actuali://accounts"))
    }

    private var netWorthColor: Color {
        if entry.balancesHidden {
            return .primary
        }
        guard let netWorth = entry.netWorth else { return .primary }
        return netWorth < 0 ? .red : .green
    }
}
