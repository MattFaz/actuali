import SwiftUI

/// The spans a detail page can switch a report to, in months ending with the
/// current one. The card keeps the range configured on the web.
enum ReportDetailRange: Int, CaseIterable, Sendable {
    case threeMonths = 3
    case sixMonths = 6
    case year = 12

    var titleKey: String {
        switch self {
        case .threeMonths: "3M"
        case .sixMonths: "6M"
        case .year: "1Y"
        }
    }

    /// A sliding window already ending on today's month, which is how
    /// `TimeFrame.resolve` keeps a window's length while moving it.
    func timeFrame(asOf today: Date) -> WidgetTimeFrame {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func month(_ offset: Int) -> String {
            let date = calendar.date(byAdding: .month, value: offset, to: today) ?? today
            let parts = calendar.dateComponents([.year, .month], from: date)
            return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        }
        return WidgetTimeFrame(start: month(1 - rawValue), end: month(0), mode: .slidingWindow)
    }

    /// Upstream's name for the same span as a custom report date range.
    var customReportDateRange: String {
        "Last \(rawValue) months"
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
    func ranged(_ range: ReportDetailRange, asOf today: Date) -> Self {
        var copy = self
        copy.timeFrame = range.timeFrame(asOf: today)
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
    /// nil when the widget has no range to move (a forecast, a simulation).
    let recompute: (@Sendable (ReportDetailRange, [Transaction]) -> Value)?
    @ViewBuilder let content: (Value) -> Content

    @State private var range: ReportDetailRange?
    @State private var ranged: Value?

    var body: some View {
        content(range == nil ? initial : ranged ?? initial)
            // A new range is a new report: selection and hidden series from
            // the old one don't carry over.
            .id(range)
            // The page places the picker in its own content, under the
            // large title, with `ReportRangePicker`.
            .environment(\.reportDetailRange, recompute == nil ? nil : $range)
            .task(id: range) {
                guard let range, let recompute else {
                    ranged = nil
                    return
                }
                let transactions = transactions
                if let value = try? await ReportComputation.compute(transactions: transactions, using: { recompute(range, $0) }) {
                    ranged = value
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
            Picker(ReportStrings.text("Time range", locale: locale), selection: range) {
                Text(ReportStrings.text("Default", locale: locale)).tag(ReportDetailRange?.none)
                ForEach(ReportDetailRange.allCases, id: \.self) { range in
                    Text(ReportStrings.text(range.titleKey, locale: locale)).tag(ReportDetailRange?.some(range))
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("reportDetail.range")
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
