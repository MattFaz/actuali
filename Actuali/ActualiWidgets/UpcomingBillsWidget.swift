import SwiftUI
import WidgetKit

struct UpcomingBillsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "UpcomingBillsWidget",
            provider: UpcomingBillsProvider()
        ) { entry in
            UpcomingBillsWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Upcoming Bills"))
        .description(String(localized: "Scheduled bills and upcoming transactions."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UpcomingBillsEntry: TimelineEntry {
    let date: Date
    let balancesHidden: Bool
    let bills: [WidgetBillItem]
    let hasSnapshot: Bool

    static let sample = UpcomingBillsEntry(
        date: .now,
        balancesHidden: false,
        bills: [
            WidgetBillItem(id: "1", title: "Electric Utility", amount: -8500, formattedAmount: "$85.00", dueDay: 29, dueMonth: 10, dueYear: 2026, status: .due),
            WidgetBillItem(id: "2", title: "Internet", amount: -6000, formattedAmount: "$60.00", dueDay: 2, dueMonth: 11, dueYear: 2026, status: .upcoming),
            WidgetBillItem(id: "3", title: "Rent", amount: -120_000, formattedAmount: "$1,200.00", dueDay: 5, dueMonth: 11, dueYear: 2026, status: .upcoming),
        ],
        hasSnapshot: true
    )
}

struct UpcomingBillsProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpcomingBillsEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (UpcomingBillsEntry) -> Void) {
        completion(context.isPreview ? .sample : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpcomingBillsEntry>) -> Void) {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [currentEntry()], policy: .after(nextMidnight)))
    }

    private func currentEntry() -> UpcomingBillsEntry {
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              snapshot.isForMonth(containing: .now) else {
            return UpcomingBillsEntry(date: .now, balancesHidden: false, bills: [], hasSnapshot: false)
        }
        return UpcomingBillsEntry(
            date: snapshot.generatedAt,
            balancesHidden: snapshot.balancesHidden,
            bills: snapshot.upcomingBills ?? [],
            hasSnapshot: true
        )
    }
}

struct UpcomingBillsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.locale) private var locale

    let entry: UpcomingBillsEntry

    var body: some View {
        Group {
            if entry.bills.isEmpty {
                emptyState
            } else if family == .systemSmall {
                smallLayout(bill: entry.bills[0])
            } else {
                mediumLayout
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "actuali://budget"))
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "calendar.badge.clock")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(entry.hasSnapshot
                ? String(localized: "No upcoming bills")
                : String(localized: "Open Actuali to load your budget"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func smallLayout(bill: WidgetBillItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(String(localized: "Next Bill"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "calendar.badge.clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(bill.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(bill.formattedAmount)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(amountColor(for: bill))
            HStack(spacing: 4) {
                Text(dateString(for: bill))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if bill.status == .overdue {
                    Text(String(localized: "Overdue"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                } else if bill.status == .due {
                    Text(String(localized: "Due"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label {
                    Text(String(localized: "Upcoming Bills"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "calendar.badge.clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(
                    format: String(localized: "Updated %@", locale: locale),
                    WidgetDateFormatting.relative(entry.date, locale: locale)
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            ForEach(Array(entry.bills.prefix(3))) { bill in
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor(bill.status))
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bill.title)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(dateString(for: bill))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(bill.formattedAmount)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(amountColor(for: bill))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func dateString(for bill: WidgetBillItem) -> String {
        var comps = DateComponents()
        comps.year = bill.dueYear
        comps.month = bill.dueMonth
        comps.day = bill.dueDay
        guard let date = Calendar.current.date(from: comps) else {
            return "\(bill.dueMonth)/\(bill.dueDay)"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    /// Income schedules read green, as in the Schedules list, so a paycheck
    /// is not mistaken for a bill. Hidden balances stay neutral so the sign does not leak.
    private func amountColor(for bill: WidgetBillItem) -> Color {
        if entry.balancesHidden {
            return .primary
        }
        return bill.amount > 0 ? .green : statusColor(bill.status)
    }

    private func statusColor(_ status: WidgetBillItem.Status) -> Color {
        switch status {
        case .overdue: .red
        case .due: .orange
        case .upcoming: .secondary
        }
    }
}
