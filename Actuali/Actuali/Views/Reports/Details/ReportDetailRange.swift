import SwiftUI

/// The spans a detail page can switch a report to. Each ends where upstream
/// ends the same span: a count of months and `all` with the current month,
/// year to date with today, and a custom report's "All time" with its last
/// transaction. The card keeps the range configured on the web.
enum ReportDetailRange: CaseIterable, Sendable {
    case threeMonths, sixMonths, yearToDate, year, all

    var titleKey: String {
        switch self {
        case .threeMonths: "3M"
        case .sixMonths: "6M"
        case .yearToDate: "YTD"
        case .year: "1Y"
        case .all: "All"
        }
    }

    /// nil for the spans that aren't a count of months back.
    private var months: Int? {
        switch self {
        case .threeMonths: 3
        case .sixMonths: 6
        case .year: 12
        case .yearToDate, .all: nil
        }
    }

    /// The month ("2024-03") of the first transaction, where `all` starts.
    /// Unset dates are skipped: an unparseable start would send a full range
    /// back to `TimeFrame`'s 1900.
    static func earliestMonth(dates: some Sequence<Int>) -> String? {
        dates.filter { $0 > 0 }.min().map { String(format: "%04d-%02d", $0 / 10000, $0 / 100 % 100) }
    }

    /// A span in months is a sliding window already ending on today's month,
    /// which is how `TimeFrame.resolve` keeps a window's length while moving
    /// it. `all` runs from the first transaction.
    ///
    /// No span is a single month: that is one point on a monthly chart, and
    /// the line and area pages need two. January's year to date, and a
    /// history that began this month, reach back one month more.
    func timeFrame(asOf today: Date, earliestMonth: String? = nil) -> WidgetTimeFrame {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func month(_ offset: Int) -> String {
            let date = calendar.date(byAdding: .month, value: offset, to: today) ?? today
            let parts = calendar.dateComponents([.year, .month], from: date)
            return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        }
        switch self {
        case .yearToDate where calendar.component(.month, from: today) > 1:
            return WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate)
        case .all:
            return WidgetTimeFrame(start: min(earliestMonth ?? month(-1), month(-1)), end: month(0), mode: .full)
        default:
            return WidgetTimeFrame(start: month(1 - (months ?? 2)), end: month(0), mode: .slidingWindow)
        }
    }

    /// Upstream's name for the same span as a custom report date range.
    var customReportDateRange: String {
        months.map { "Last \($0) months" } ?? (self == .yearToDate ? "Year to date" : "All time")
    }
}

/// Widget metas whose time frame a detail page can replace.
protocol TimeFramedMeta {
    var timeFrame: WidgetTimeFrame? { get set }
    /// Called for `all`. A whole history in days or weeks is thousands of
    /// points to compute and draw, so a meta with an interval that fine
    /// moves to months.
    mutating func coarsenForAllTime()
}

extension TimeFramedMeta {
    mutating func coarsenForAllTime() {}
}

extension NetWorthMeta: TimeFramedMeta {
    mutating func coarsenForAllTime() {
        if interval == .daily || interval == .weekly {
            interval = .monthly
        }
    }
}

extension CashFlowMeta: TimeFramedMeta {}
extension AgeOfMoneyMeta: TimeFramedMeta {}
extension BudgetAnalysisMeta: TimeFramedMeta {}
extension CalendarMeta: TimeFramedMeta {}
extension SankeyMeta: TimeFramedMeta {}

extension TimeFramedMeta {
    func ranged(_ range: ReportDetailRange, asOf today: Date, earliestMonth: String? = nil) -> Self {
        var copy = self
        copy.timeFrame = range.timeFrame(asOf: today, earliestMonth: earliestMonth)
        if range == .all {
            copy.coarsenForAllTime()
        }
        return copy
    }
}

extension CustomReportConfig {
    func ranged(_ range: ReportDetailRange) -> CustomReportConfig {
        var copy = self
        copy.dateStatic = false
        copy.dateRange = range.customReportDateRange
        // As `TimeFramedMeta.coarsenForAllTime`.
        if range == .all, ["Daily", "Weekly"].contains(interval) {
            copy.interval = "Monthly"
        }
        return copy
    }
}

/// Hosts a detail page and, when the widget's range can move, a range picker
/// that recomputes the report from the dashboard's transactions.
struct ReportRangedDetail<Value: Sendable, Content: View>: View {
    /// What the card shows: the range configured on the web.
    let initial: Value
    let transactions: [Transaction]
    /// Bumped when the budget data changes, so a picked range recomputes too.
    var dataVersion = 0
    /// nil when the widget has no range to move (a forecast, a simulation).
    let recompute: (@Sendable (ReportDetailRange, [Transaction]) -> Value)?
    @ViewBuilder let content: (Value) -> Content

    @State private var range: ReportDetailRange?
    @State private var ranged: (range: ReportDetailRange, value: Value)?

    private struct Inputs: Hashable {
        let range: ReportDetailRange?
        let dataVersion: Int
    }

    /// Only a value computed for the picked range stands in for it; until
    /// then the page keeps the card's own, not the previous range's.
    nonisolated static func shown(
        initial: Value, ranged: (range: ReportDetailRange, value: Value)?, range: ReportDetailRange?
    ) -> Value {
        ranged.flatMap { $0.range == range ? $0.value : nil } ?? initial
    }

    /// A range was picked and its report hasn't arrived: what's on screen
    /// is still the card's.
    nonisolated static func isPending(ranged: (range: ReportDetailRange, value: Value)?, range: ReportDetailRange?) -> Bool {
        range != nil && ranged?.range != range
    }

    var body: some View {
        let pending = Self.isPending(ranged: ranged, range: range)
        content(Self.shown(initial: initial, ranged: ranged, range: range))
            // Placeholders until the picked range's numbers replace the
            // card's, so they aren't read as the new range. The pages mark
            // what to cover with `loadingPlaceholder`, which leaves the
            // picker and the other controls alone.
            .environment(\.reportRangePending, pending)
            // The page places the picker in its own content, under the
            // large title, with `ReportRangePicker`.
            .environment(\.reportDetailRange, recompute == nil ? nil : $range)
            .task(id: Inputs(range: range, dataVersion: dataVersion)) {
                guard let range, let recompute else {
                    ranged = nil
                    return
                }
                let transactions = transactions
                let started = ContinuousClock.now
                if let value = try? await ReportComputation.compute(transactions: transactions, using: { recompute(range, $0) }) {
                    // Most ranges compute in a frame or two. Hold a newly
                    // picked one for a full sweep of the shimmer, so the
                    // placeholders read as loading rather than a flicker.
                    if Self.isPending(ranged: ranged, range: range) {
                        try? await Task.sleep(until: started + .milliseconds(800), clock: .continuous)
                    }
                    if !Task.isCancelled {
                        ranged = (range, value)
                    }
                }
            }
    }
}

extension ReportRangePicker {
    private static let optionPadding: CGFloat = 12

    private func options(_ range: Binding<ReportDetailRange?>) -> some View {
        let all: [ReportDetailRange?] = [nil] + ReportDetailRange.allCases
        return HStack(spacing: 0) {
            ForEach(all, id: \.self) { option in
                if option != nil {
                    Spacer(minLength: 0)
                }
                let isSelected = option == range.wrappedValue
                Button {
                    range.wrappedValue = option
                } label: {
                    Text(ReportStrings.text(option?.titleKey ?? "Saved", locale: locale))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                        .padding(.horizontal, Self.optionPadding)
                        .padding(.vertical, 6)
                        .background(isSelected ? Color(.tertiarySystemFill) : .clear, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("reportDetail.range.\(option?.titleKey ?? "Saved")")
            }
        }
    }
}

/// The range control a detail page shows at the top of its content. Draws
/// nothing when the widget has no range to move.
struct ReportRangePicker: View {
    @Environment(\.reportDetailRange) private var range
    @Environment(\.locale) private var locale

    var body: some View {
        if let range {
            // Each option as wide as its own label, not a segmented
            // control's equal shares: "Saved" is long in some languages
            // and the rest are two or three letters. Scrolls only where
            // even that doesn't fit.
            ViewThatFits(in: .horizontal) {
                options(range)
                ScrollView(.horizontal) { options(range) }
                    .scrollIndicators(.hidden)
            }
            // The labels, not the capsule around the picked one, line up
            // with the text below.
            .padding(.horizontal, -Self.optionPadding)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(ReportStrings.text("Time range", locale: locale))
            .accessibilityIdentifier("reportDetail.range")
        }
    }
}

// MARK: - Card affordance

extension EnvironmentValues {
    /// Set on a card that opens a detail page, so its title shows a chevron.
    @Entry var reportCardLinksToDetail = false
    /// A picked range is still loading: see `loadingPlaceholder`.
    @Entry var reportRangePending = false
    /// The detail page's range selection, when its widget has one.
    @Entry var reportDetailRange: Binding<ReportDetailRange?>?
}

extension View {
    /// A new range is a new report: a selection made in the old one doesn't
    /// carry over. The page resets it rather than being rebuilt, which would
    /// blank its navigation title until the range loads.
    func onReportRangeChange(_ reset: @escaping () -> Void) -> some View {
        modifier(ReportRangeChange(reset: reset))
    }
}

private struct ReportRangeChange: ViewModifier {
    @Environment(\.reportDetailRange) private var range
    let reset: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: range?.wrappedValue) { reset() }
    }
}

/// A report card's title, with a chevron when the card opens a detail page.
struct ReportCardTitle: View {
    @Environment(\.reportCardLinksToDetail) private var linksToDetail
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.headline)
            if linksToDetail {
                // Decorative: the card itself is the button.
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}
