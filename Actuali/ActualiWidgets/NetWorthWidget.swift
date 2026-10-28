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
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              snapshot.isForMonth(containing: .now) else {
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
    @Environment(\.widgetFamily) private var family
    @Environment(\.locale) private var locale

    let entry: NetWorthEntry
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
        .widgetURL(URL(string: "actuali://accounts"))
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(String(localized: "Net Worth"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let formatted = entry.formattedNetWorth {
                Text(formatted)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .foregroundStyle(netWorthColor)
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
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.caption)
            if let formatted = entry.formattedNetWorth {
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
            Text(String(localized: "Net Worth"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let formatted = entry.formattedNetWorth {
                Text(formatted)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else {
                Text(String(localized: "Open Actuali"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var inlineLayout: some View {
        Group {
            if let formatted = entry.formattedNetWorth {
                Text(String(
                    format: String(localized: "Net Worth: %@", locale: locale),
                    formatted
                ))
            } else {
                Text(String(localized: "Net Worth: —"))
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var netWorthColor: Color {
        if entry.balancesHidden {
            return .primary
        }
        guard let netWorth = entry.netWorth else { return .primary }
        return netWorth < 0 ? .red : .green
    }
}
