import SwiftUI
import WidgetKit

struct QuickAddTransactionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "QuickAddTransactionWidget",
            provider: QuickAddTransactionProvider()
        ) { entry in
            QuickAddTransactionWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Add Transaction"))
        .description(String(localized: "Quickly open Actuali to record a new transaction."))
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

struct QuickAddTransactionEntry: TimelineEntry {
    let date: Date

    static let sample = QuickAddTransactionEntry(date: .now)
}

struct QuickAddTransactionProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickAddTransactionEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickAddTransactionEntry) -> Void) {
        completion(.sample)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickAddTransactionEntry>) -> Void) {
        let entry = QuickAddTransactionEntry(date: .now)
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
    }
}

struct QuickAddTransactionWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: QuickAddTransactionEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                rectangularLayout
            case .accessoryInline:
                inlineLayout
            default:
                circularLayout
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "actuali://add-transaction"))
    }

    private var circularLayout: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "creditcard.badge.plus")
                .font(.title3)
        }
    }

    private var rectangularLayout: some View {
        HStack(spacing: 8) {
            Image(systemName: "creditcard.badge.plus")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Add Transaction"))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(String(localized: "Record spending"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inlineLayout: some View {
        Label(String(localized: "Add Transaction"), systemImage: "creditcard.badge.plus")
    }
}
