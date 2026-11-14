import SwiftUI

/// What a chart detail page shows, whichever widget it came from: intervals
/// along the x-axis and one or more named series. Each chart widget maps its
/// own data to this, so one page serves them all.
struct ReportChartDetail: Equatable {
    enum Style: Equatable { case stackedBars, groupedBars, lines, area }
    enum Unit: Equatable { case currency, days }
    /// The headline number: the sum of the visible series, the first series
    /// (when the others are context for it), the first minus the second
    /// (income less expenses), or none (when no single number leads).
    enum Readout: Equatable { case total, first, difference, none }

    /// A shaded range behind the lines, such as a percentile spread.
    struct Band: Equatable {
        var lowerName: String
        var upperName: String
        var lower: [Double]
        var upper: [Double]
        var color: Color
    }

    /// A figure for the whole range, listed under the chart.
    struct Stat: Equatable {
        enum Value: Equatable { case amount(Double), text(String) }

        var label: String
        var value: Value
    }

    struct Event: Equatable {
        var name: String
        var date: String
        var amount: Double
    }

    struct Series: Equatable {
        var name: String
        var color: Color
        var values: [Double]
        /// Line charts: the index the line turns dashed at (forecast, projection).
        var dashedFrom: Int?
        /// Line charts: a least-squares trend from the first interval to the last.
        var trend: CustomReportData.Trend?
    }

    var name: String
    var caption = ""
    var intervals: [String]
    /// What the x-axis writes at each interval where the range under the
    /// headline already gives the full dates: a month or a year where one
    /// starts, empty elsewhere. nil to write the intervals themselves.
    var axisLabels: [String]?
    var series: [Series]
    var style: Style
    var unit = Unit.currency
    var readout = Readout.total
    /// What the headline number is, shown under it.
    var readoutLabel = ""
    /// Single-series bars coloured by sign.
    var signed = false
    var band: Band?
    var stats: [Stat] = []
    /// Dated items behind the chart, listed under it (a forecast's schedules).
    var events: [Event] = []
    /// Abbreviate amounts ("690K"): for figures too large to need their cents.
    var compact = false
    var card = Card()

    /// What the dashboard card leads with, where it isn't simply the readout
    /// at the latest interval.
    struct Card: Equatable {
        /// A headline that isn't an amount in the chart's unit ("87%").
        var text: String?
        /// A headline amount other than the latest readout (a forecast's low).
        var value: Double?
        /// The words beside the headline; the latest interval when nil.
        var context: String?
        /// Show the change across the range beside the headline.
        var showsChange = false
        var compact = false
    }

    /// False when there is nothing to chart, or the labels repeat: a string
    /// axis merges equal labels into one position.
    var isChartable: Bool {
        !intervals.isEmpty && !series.isEmpty
            && Set(intervals).count == intervals.count
            && series.allSatisfy { $0.values.count == intervals.count }
            && (axisLabels.map { $0.count == intervals.count } ?? true)
            && (band.map { $0.lower.count == intervals.count && $0.upper.count == intervals.count } ?? true)
    }

    /// Two or three series that can't be switched off read better beside the
    /// headline than as a list under the chart.
    var showsInlineLegend: Bool {
        !canHideSeries && (2...3).contains(series.count)
    }

    /// Series can be switched off only where the headline is their sum.
    var canHideSeries: Bool {
        readout == .total && series.count > 1
    }

    /// Stacked bars can also be read as one bar per interval: their sum.
    var canShowTotal: Bool {
        style == .stackedBars && canHideSeries
    }

    /// The series still shown, added up into one.
    func totalled(hiding hidden: Set<Int> = []) -> ReportChartDetail {
        let values = intervals.indices.map { readoutValue(at: $0, hiding: hidden) ?? 0 }
        var total = self
        total.series = [.init(name: name, color: .accentColor, values: values)]
        // A sum that can go negative reads by its sign, like a net report.
        total.signed = values.contains { $0 < 0 }
        return total
    }

    func readoutValue(at interval: Int, hiding hidden: Set<Int> = []) -> Double? {
        switch readout {
        case .total: series.indices.filter { !hidden.contains($0) }.reduce(0) { $0 + series[$1].values[interval] }
        case .first: series[0].values[interval]
        case .difference: series.count > 1 ? series[0].values[interval] - series[1].values[interval] : nil
        case .none: nil
        }
    }

    fileprivate var chartable: ReportChartDetail? {
        isChartable ? self : nil
    }
}

extension ReportChartDetail {
    /// Change, high and low: for a series that is a level at each interval
    /// (a balance), where a sum over the range would mean nothing.
    static func levelStats(_ values: [Double], locale: Locale) -> [Stat] {
        guard let first = values.first, let last = values.last else { return [] }
        return [
            .init(label: ReportStrings.text("Change", locale: locale), value: .amount(last - first)),
            .init(label: ReportStrings.text("High", locale: locale), value: .amount(values.max() ?? last)),
            .init(label: ReportStrings.text("Low", locale: locale), value: .amount(values.min() ?? last)),
        ]
    }
}

enum ReportDetailLabels {
    private static let utc = TimeZone(identifier: "UTC")!

    /// "Nov 26" when every date starts a month, otherwise "Nov 13, 26". UTC,
    /// like the engines that produced the dates.
    static func dates(_ dates: [Date], locale: Locale, alwaysDay: Bool = false) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let monthly = !alwaysDay && dates.allSatisfy { calendar.component(.day, from: $0) == 1 }
        let base = Date.FormatStyle(locale: locale, timeZone: utc).month(.abbreviated).year(.twoDigits)
        return dates.map { $0.formatted(monthly ? base : base.day()) }
    }

    /// The short form for the axis: "Nov" where a month starts, or "2027"
    /// where a year starts once the range is too long for month names to
    /// tell apart. Empty for the dates in between.
    static func axis(_ dates: [Date], locale: Locale) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let months = dates.map { calendar.dateComponents([.year, .month], from: $0) }
        let style = Date.FormatStyle(locale: locale, timeZone: utc)
        let byYear = Set(months).count > 12
        return dates.indices.map { index in
            if byYear {
                return index > 0 && months[index].year != months[index - 1].year ? dates[index].formatted(style.year()) : ""
            }
            return index == 0 || months[index] != months[index - 1] ? dates[index].formatted(style.month(.abbreviated)) : ""
        }
    }

    /// Budget months arrive as YYYYMM integers.
    static func monthDates(_ months: [Int]) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return months.map {
            calendar.date(from: DateComponents(year: $0 / 100, month: $0 % 100, day: 1)) ?? .distantPast
        }
    }
}

// MARK: - Widgets

extension CustomReportData {
    /// Donut and table reports have no intervals to chart: see `breakdown`.
    func chartDetail(locale: Locale = .current) -> ReportChartDetail? {
        func detail(
            _ table: Stacked, _ style: ReportChartDetail.Style, signed: Bool = false, trends: [Trend] = []
        ) -> ReportChartDetail? {
            let palette = CustomReportWidgetView.palette
            let single = table.seriesNames.count == 1
            return ReportChartDetail(
                name: name, caption: rangeLabel, intervals: table.intervalLabels,
                series: table.seriesNames.indices.map {
                    .init(name: table.seriesNames[$0], color: single ? .accentColor : palette[$0 % palette.count],
                          values: table.values[$0],
                          // Empty unless the report has trend lines switched on.
                          trend: trends.indices.contains($0) ? trends[$0] : nil)
                },
                style: style, signed: signed,
                // Bars are amounts per interval, so they add up; a line or an
                // area is a level at each interval and doesn't.
                stats: single && style == .stackedBars
                    ? [.init(label: ReportStrings.text("Total", locale: locale), value: .amount(table.values[0].reduce(0, +)))] : []
            ).chartable
        }
        func single(_ bars: [Bar]) -> Stacked {
            Stacked(intervalLabels: bars.map(\.label), seriesNames: [name], values: [bars.map(\.valueUnits)])
        }
        return switch kind {
        case .stacked(let stacked): detail(stacked, .stackedBars)
        case .lines(let stacked, let trends): detail(stacked, .lines, trends: trends)
        case .bars(let bars, let signed): detail(single(bars), .stackedBars, signed: signed)
        case .area(let bars): detail(single(bars), .area)
        case .donut, .table, .unsupported: nil
        }
    }
}

extension NetWorthData {
    func chartDetail(name: String, locale: Locale) -> ReportChartDetail? {
        guard points.count >= 2 else { return nil }
        let values = points.map { Double($0.balanceCents) / 100 }
        return ReportChartDetail(
            name: name, intervals: ReportDetailLabels.dates(points.map(\.date), locale: locale),
            axisLabels: ReportDetailLabels.axis(points.map(\.date), locale: locale),
            series: [.init(name: name, color: .green, values: values)],
            style: .area, stats: ReportChartDetail.levelStats(values, locale: locale),
            card: .init(showsChange: true, compact: true)
        ).chartable
    }
}

extension CashFlowData {
    func chartDetail(name: String, locale: Locale) -> ReportChartDetail? {
        let income = points.reduce(0) { $0 + Double($1.incomeCents) / 100 }
        let expenses = points.reduce(0) { $0 + Double($1.expenseCents) / 100 }
        return ReportChartDetail(
            name: name, intervals: ReportDetailLabels.dates(points.map(\.periodStart), locale: locale),
            axisLabels: ReportDetailLabels.axis(points.map(\.periodStart), locale: locale),
            series: [
                .init(name: ReportStrings.text("Income", locale: locale), color: .green,
                      values: points.map { Double($0.incomeCents) / 100 }),
                .init(name: ReportStrings.text("Expense", locale: locale), color: .red,
                      values: points.map { Double($0.expenseCents) / 100 }),
            ],
            style: .groupedBars, readout: .difference, readoutLabel: ReportStrings.text("Net", locale: locale),
            stats: [
                .init(label: ReportStrings.text("Total income", locale: locale), value: .amount(income)),
                .init(label: ReportStrings.text("Total expenses", locale: locale), value: .amount(expenses)),
                .init(label: ReportStrings.text("Net", locale: locale), value: .amount(income - expenses)),
            ]
        ).chartable
    }
}

extension AgeOfMoneyData {
    func chartDetail(name: String) -> ReportChartDetail? {
        guard points.count >= 2 else { return nil }
        return ReportChartDetail(
            name: name, intervals: points.map(\.monthLabel),
            series: [.init(name: name, color: .teal, values: points.map { Double($0.age) })],
            style: .area, unit: .days, card: .init(showsChange: true)
        ).chartable
    }
}

extension BudgetAnalysisData {
    func chartDetail(name: String, locale: Locale) -> ReportChartDetail? {
        let months = ReportDetailLabels.monthDates(intervalData.map(\.month))
        let intervals = ReportDetailLabels.dates(months, locale: locale)
        let axisLabels = ReportDetailLabels.axis(months, locale: locale)
        func series(_ key: String, _ color: Color, _ cents: (BudgetAnalysisIntervalPoint) -> Int) -> ReportChartDetail.Series {
            .init(name: ReportStrings.text(key, locale: locale), color: color, values: intervalData.map { Double(cents($0)) / 100 })
        }
        if balanceOnly {
            return ReportChartDetail(name: name, intervals: intervals, axisLabels: axisLabels,
                                     series: [series("Balance", .gray, \.balanceCents)], style: .lines).chartable
        }
        return ReportChartDetail(
            name: name, intervals: intervals, axisLabels: axisLabels,
            // Spending is stored negative; the bars compare magnitudes.
            series: [series("Budgeted", .green, \.budgetedCents), series("Spent", .red) { abs($0.spentCents) }],
            style: graphType == .line ? .lines : .groupedBars,
            readout: .difference, readoutLabel: ReportStrings.text("Balance", locale: locale)
        ).chartable
    }
}

extension BalanceForecastData {
    /// The list has room for the next few occurrences, not a year of them.
    static let upcomingLimit = 6

    func chartDetail(name: String, payeeNames: [String: String] = [:], locale: Locale) -> ReportChartDetail? {
        guard points.count >= 2 else { return nil }
        let values = points.map { Double($0.balanceCents) / 100 }
        let labels = ReportDetailLabels.dates(points.map(\.date), locale: locale)
        let lowest = points.indices.filter { points[$0].isForecast }.min { values[$0] < values[$1] }
        return ReportChartDetail(
            name: name, intervals: labels, axisLabels: ReportDetailLabels.axis(points.map(\.date), locale: locale),
            series: [.init(name: name, color: .blue, values: values,
                           dashedFrom: points.firstIndex(where: \.isForecast))],
            style: .lines, stats: ReportChartDetail.levelStats(values, locale: locale),
            events: zip(upcoming.prefix(Self.upcomingLimit),
                        ReportDetailLabels.dates(upcoming.prefix(Self.upcomingLimit).map(\.date), locale: locale, alwaysDay: true)).map {
                // Like the schedules list: an unnamed schedule goes by its payee.
                .init(name: $0.scheduleName ?? $0.payeeId.flatMap { payeeNames[$0] } ?? ReportStrings.text("Schedule", locale: locale),
                      date: $1, amount: Double($0.amountCents) / 100)
            },
            // The number that matters on a forecast is how low it gets.
            card: .init(value: lowest.map { values[$0] },
                        context: lowest.map { ReportStrings.text("Low", locale: locale) + " · " + labels[$0] })
        ).chartable
    }
}

extension CrossoverData {
    func chartDetail(name: String, locale: Locale) -> ReportChartDetail? {
        guard points.count >= 2 else { return nil }
        let projection = points.firstIndex(where: \.isProjection)
        return ReportChartDetail(
            name: name, intervals: ReportDetailLabels.dates(points.map(\.month), locale: locale),
            axisLabels: ReportDetailLabels.axis(points.map(\.month), locale: locale),
            series: [
                .init(name: ReportStrings.text("Investment income", locale: locale), color: .green,
                      values: points.map { Double($0.investmentIncomeCents) / 100 }, dashedFrom: projection),
                .init(name: ReportStrings.text("Expenses", locale: locale), color: .red,
                      values: points.map { Double($0.expensesCents) / 100 }, dashedFrom: projection),
            ],
            style: .lines, readout: .none,
            stats: [
                yearsToRetire.map {
                    ReportChartDetail.Stat(label: ReportStrings.text("Years to Retire", locale: locale),
                                           value: .text(ReportStrings.yearsToRetire($0, locale: locale)))
                },
                crossoverMonth.map {
                    ReportChartDetail.Stat(label: ReportStrings.text("Crossover", locale: locale),
                                           value: .text(ReportDetailLabels.dates([$0], locale: locale)[0]))
                },
            ].compactMap(\.self),
            card: .init(text: yearsToRetire.map { ReportStrings.yearsToRetire($0, locale: locale) },
                        context: ReportStrings.text("Years to Retire", locale: locale))
        ).chartable
    }
}

extension MonteCarloData {
    func chartDetail(name: String, locale: Locale) -> ReportChartDetail? {
        guard percentileBands.count >= 2 else { return nil }
        func series(_ name: String, _ color: Color, _ cents: (MonteCarloPercentileBand) -> Int) -> ReportChartDetail.Series {
            .init(name: name, color: color, values: percentileBands.map { Double(cents($0)) / 100 })
        }
        return ReportChartDetail(
            name: name,
            // The x-axis is the age reached in each simulated year.
            intervals: percentileBands.map { (currentAge + Double($0.year)).formatted(.number.locale(locale).precision(.fractionLength(0))) },
            series: [series(ReportStrings.text("Median", locale: locale), .purple, \.p50)],
            style: .lines, readoutLabel: ReportStrings.text("Median", locale: locale),
            band: .init(lowerName: "p10", upperName: "p90",
                        lower: percentileBands.map { Double($0.p10) / 100 },
                        upper: percentileBands.map { Double($0.p90) / 100 }, color: .purple),
            stats: [
                // Upstream rounds the rate to a tenth of a percent.
                .init(label: ReportStrings.text("Success rate", locale: locale),
                      value: .text(MonteCarloWidgetFormatting.percentage((successRate * 1000).rounded() / 10, locale: locale))),
                .init(label: ReportStrings.text("Simulations", locale: locale),
                      value: .text(simulationCount.formatted(.number.locale(locale)))),
            ],
            compact: true,
            card: .init(text: MonteCarloWidgetFormatting.percentage((successRate * 1000).rounded() / 10, locale: locale),
                        context: ReportStrings.text("Success rate", locale: locale))
        ).chartable
    }
}
