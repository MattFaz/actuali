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
        .supportedFamilies(WidgetFamily.systemFamilies())
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
        completion(context.isPreview ? .sample : currentEntry(for: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpcomingBillsEntry>) -> Void) {
        let nextMidnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [currentEntry(for: context.family)], policy: .after(nextMidnight)))
    }

    private func currentEntry(for family: WidgetFamily) -> UpcomingBillsEntry {
        let limit = switch family {
        case .systemSmall: 1
        case .systemMedium: 3
        case .systemLarge: 6
        default: 12 // systemExtraLargePortrait; the case itself is iOS 27-only
        }
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              snapshot.isForMonth(containing: .now) else {
            return UpcomingBillsEntry(date: .now, balancesHidden: false, bills: [], hasSnapshot: false)
        }
        return UpcomingBillsEntry(
            date: snapshot.generatedAt,
            balancesHidden: snapshot.balancesHidden,
            bills: snapshot.nextBills(limit: limit),
            hasSnapshot: true
        )
    }
}

struct UpcomingBillsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let entry: UpcomingBillsEntry

    var body: some View {
        Group {
            if entry.bills.isEmpty {
                emptyState
            } else if family == .systemSmall {
                smallLayout(bill: entry.bills[0])
            } else {
                listLayout
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

    /// Medium, large, and extra-large portrait share this list; only the
    /// provider's row limit differs per family. Medium keeps "Updated" in the
    /// header because a footer line under three two-line rows overfills it.
    private var listLayout: some View {
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
                if family == .systemMedium {
                    WidgetUpdatedFooter(date: entry.date)
                }
            }

            if family == .systemMedium, dynamicTypeSize <= .large {
                // Unchanged from before Large existed: three rows that lean
                // a few points into the bottom content margin, which a fit
                // check below would count as overflow and cut to two. Above
                // the default size they overflow outright and clip the
                // header, so those sizes take the fit check instead.
                billRows(entry.bills[...])
            } else {
                // Drop trailing bills rather than clip them when Dynamic Type
                // (the widget cap is XXX Large) or a smaller device leaves less
                // height than the provider's row limit needs. Soonest bills win.
                ViewThatFits(in: .vertical) {
                    ForEach((1...entry.bills.count).reversed(), id: \.self) { count in
                        billRows(entry.bills.prefix(count))
                    }
                }
                // Claim the height before the Spacer below, or the VStack
                // splits it between them and drops a row that fits.
                .layoutPriority(1)
            }
            Spacer(minLength: 0)
            if family != .systemMedium {
                WidgetUpdatedFooter(date: entry.date)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func billRows(_ bills: ArraySlice<WidgetBillItem>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(bills) { bill in
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
                        .monospacedDigit()
                        .lineLimit(1)
                        // Truncate the title, never the amount, at large Dynamic Type sizes.
                        .layoutPriority(1)
                        .foregroundStyle(amountColor(for: bill))
                }
                .accessibilityIdentifier("upcomingBillsWidget.billRow")
            }
        }
    }

    private func dateString(for bill: WidgetBillItem) -> String {
        WidgetDateFormatting.shortDate(bill.dueYear * 10000 + bill.dueMonth * 100 + bill.dueDay, locale: locale)
            ?? "\(bill.dueMonth)/\(bill.dueDay)"
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
