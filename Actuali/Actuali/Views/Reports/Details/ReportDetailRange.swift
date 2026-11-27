import SwiftUI

/// The spans a detail page can switch a report to, all ending with the
/// current month. The card keeps the range configured on the web.
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
    /// it. `all` runs from the first transaction; with none, this month.
    func timeFrame(asOf today: Date, earliestMonth: String? = nil) -> WidgetTimeFrame {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func month(_ offset: Int) -> String {
            let date = calendar.date(byAdding: .month, value: offset, to: today) ?? today
            let parts = calendar.dateComponents([.year, .month], from: date)
            return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        }
        if let months {
            return WidgetTimeFrame(start: month(1 - months), end: month(0), mode: .slidingWindow)
        }
        return self == .yearToDate
            ? WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate)
            : WidgetTimeFrame(start: earliestMonth ?? month(0), end: month(0), mode: .full)
    }

    /// Upstream's name for the same span as a custom report date range.
    var customReportDateRange: String {
        months.map { "Last \($0) months" } ?? (self == .yearToDate ? "Year to date" : "All time")
    }
}

/// Widget metas whose time frame a detail page can replace.
protocol TimeFramedMeta {
    var timeFrame: WidgetTimeFrame? { get set }
}

extension NetWorthMeta: TimeFramedMeta {}
extension CashFlowMeta: TimeFramedMeta {}
extension AgeOfMoneyMeta: TimeFramedMeta {}
extension BudgetAnalysisMeta: TimeFramedMeta {}
extension CalendarMeta: TimeFramedMeta {}
extension SankeyMeta: TimeFramedMeta {}

extension TimeFramedMeta {
    func ranged(_ range: ReportDetailRange, asOf today: Date, earliestMonth: String? = nil) -> Self {
        var copy = self
        copy.timeFrame = range.timeFrame(asOf: today, earliestMonth: earliestMonth)
        return copy
    }
}

extension CustomReportConfig {
    func ranged(_ range: ReportDetailRange) -> CustomReportConfig {
        var copy = self
        copy.dateStatic = false
        copy.dateRange = range.customReportDateRange
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
            // Stepped back until the picked range's numbers replace the
            // card's, so they aren't read as the new range.
            .opacity(pending ? 0.4 : 1)
            .animation(.default, value: pending)
            // A new range is a new report: selection and hidden series from
            // the old one don't carry over.
            .id(range)
            // The page places the picker in its own content, under the
            // large title, with `ReportRangePicker`.
            .environment(\.reportDetailRange, recompute == nil ? nil : $range)
            .task(id: Inputs(range: range, dataVersion: dataVersion)) {
                guard let range, let recompute else {
                    ranged = nil
                    return
                }
                let transactions = transactions
                if let value = try? await ReportComputation.compute(transactions: transactions, using: { recompute(range, $0) }) {
                    ranged = (range, value)
                }
            }
    }
}

extension ReportRangePicker {
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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(isSelected ? Color(.tertiarySystemFill) : .clear, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(option)
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
            VStack(alignment: .leading, spacing: 2) {
                // Each option as wide as its own label, not a segmented
                // control's equal shares: "Saved" is long in some languages
                // and the rest are two or three letters. Scrolls only where
                // even that doesn't fit.
                ViewThatFits(in: .horizontal) {
                    options(range)
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) { options(range) }
                            .scrollIndicators(.hidden)
                            // Picking a range rebuilds the page, and the row
                            // with it: bring the pick back into view.
                            .onAppear { proxy.scrollTo(range.wrappedValue, anchor: .center) }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(ReportStrings.text("Time range", locale: locale))
                .accessibilityIdentifier("reportDetail.range")
                // Which range is the report's own, and that picking another
                // doesn't write back to it.
                Text(ReportStrings.text(
                    range.wrappedValue == nil
                        ? "The range saved with this report in Actual Budget."
                        : "Shown here only. The report keeps its saved range.",
                    locale: locale
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Card affordance

extension EnvironmentValues {
    /// Set on a card that opens a detail page, so its title shows a chevron.
    @Entry var reportCardLinksToDetail = false
    /// The detail page's range selection, when its widget has one.
    @Entry var reportDetailRange: Binding<ReportDetailRange?>?
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
