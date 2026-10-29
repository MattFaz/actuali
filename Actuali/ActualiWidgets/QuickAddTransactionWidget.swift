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
        .supportedFamilies([.accessoryCircular])
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
        // Static content: nothing to refresh.
        completion(Timeline(entries: [.sample], policy: .never))
    }
}

struct QuickAddTransactionWidgetView: View {
    let entry: QuickAddTransactionEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            // creditcard.badge.plus is SF Symbols 8 (iOS 27) and renders blank on iOS 18.
            Image(systemName: "plus")
                .font(.title3)
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "actuali://add-transaction"))
    }
}
