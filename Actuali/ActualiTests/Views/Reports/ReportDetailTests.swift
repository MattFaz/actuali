import Foundation
import SwiftUI
import Testing
@testable import Actuali

@MainActor
struct ReportDetailTests {
    private let stacked = CustomReportData.Stacked(
        intervalLabels: ["Jan", "Feb", "Mar"],
        seriesNames: ["Brokerage", "401(k)", "HSA"],
        values: [[100, -200, 300], [10, 20, 30], [1, 2, 3]]
    )

    private func report(_ kind: CustomReportData.Kind) -> CustomReportData {
        CustomReportData(name: "Report", rangeLabel: "", kind: kind)
    }

    // MARK: - Custom report

    @Test func customReportChartKindsMapToADetail() throws {
        let stackedDetail = try #require(report(.stacked(stacked)).chartDetail)
        #expect(stackedDetail.style == .stackedBars)
        #expect(stackedDetail.intervals == ["Jan", "Feb", "Mar"])
        #expect(stackedDetail.series.map(\.name) == ["Brokerage", "401(k)", "HSA"])
        #expect(stackedDetail.series.map(\.values) == stacked.values)
        #expect(stackedDetail.canHideSeries)
        #expect(report(.lines(stacked, trends: [])).chartDetail?.style == .lines)

        let bars = [CustomReportData.Bar(label: "Jan", valueUnits: 5), .init(label: "Feb", valueUnits: -7)]
        let signed = try #require(report(.bars(bars, signed: true)).chartDetail)
        #expect(signed.signed)
        #expect(signed.series.map(\.values) == [[5, -7]])
        // One series: nothing to switch off.
        #expect(!signed.canHideSeries)
        #expect(report(.area(bars)).chartDetail?.style == .area)
    }

    @Test func cardsThatAlreadyListEverythingHaveNoDetail() {
        #expect(report(.donut(slices: [.init(label: "Rent", valueUnits: 1, group: nil)], groups: [])).chartDetail == nil)
        #expect(report(.table([.init(name: "Rent", totalUnits: 1)], totalUnits: 1)).chartDetail == nil)
        #expect(report(.unsupported("nope")).chartDetail == nil)
        // Nothing to scrub through.
        #expect(report(.bars([], signed: false)).chartDetail == nil)
        #expect(report(.stacked(.init(intervalLabels: ["Jan"], seriesNames: [], values: []))).chartDetail == nil)
    }

    @Test func repeatedLabelsAreNotChartable() {
        // A string axis merges equal labels into one position.
        let bars = [CustomReportData.Bar(label: "Rent", valueUnits: 5), .init(label: "Rent", valueUnits: 7)]
        #expect(report(.bars(bars, signed: false)).chartDetail == nil)
    }

    @Test func readoutFollowsTheChartsMeaning() throws {
        let total = try #require(report(.stacked(stacked)).chartDetail)
        #expect(total.readoutValue(at: 0) == 111)
        #expect(total.readoutValue(at: 1, hiding: [0]) == 22)
        #expect(total.readoutValue(at: 2, hiding: [0, 1, 2]) == 0)

        var first = total
        first.readout = .first
        #expect(first.readoutValue(at: 1) == -200)
        #expect(!first.canHideSeries)

        var none = total
        none.readout = .none
        #expect(none.readoutValue(at: 1) == nil)
    }

    // MARK: - Other chart widgets

    private let locale = Locale(identifier: "en_US")

    private func utc(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
        var components = DateComponents(); components.year = year; components.month = month; components.day = day
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test func dateLabelsShowTheDayOnlyWhenSomeDateNeedsIt() {
        #expect(ReportDetailLabels.dates([utc(2026, 10), utc(2026, 11)], locale: locale) == ["Oct 26", "Nov 26"])
        #expect(ReportDetailLabels.dates([utc(2026, 11, 1), utc(2026, 11, 13)], locale: locale) == ["Nov 1, 26", "Nov 13, 26"])
        #expect(ReportDetailLabels.months([202_512, 202_601], locale: locale) == ["Dec 25", "Jan 26"])
    }

    @Test func netWorthIsOneAreaSeries() throws {
        let data = NetWorthData(points: [.init(date: utc(2026, 10), balanceCents: 100_000), .init(date: utc(2026, 11), balanceCents: 125_050)])
        let detail = try #require(data.chartDetail(name: "Net Worth", locale: locale))
        #expect(detail.style == .area)
        #expect(detail.intervals == ["Oct 26", "Nov 26"])
        #expect(detail.series.map(\.values) == [[1000, 1250.5]])
        #expect(detail.readoutValue(at: 1) == 1250.5)
        // A single point has no trend to open.
        #expect(NetWorthData(points: [.init(date: utc(2026, 11), balanceCents: 1)]).chartDetail(name: "", locale: locale) == nil)
    }

    @Test func cashFlowPairsIncomeAndExpensesWithoutAHeadlineSum() throws {
        let data = CashFlowData(points: [.init(periodStart: utc(2026, 10), incomeCents: 740_000, expenseCents: 565_000)])
        let detail = try #require(data.chartDetail(name: "Cash Flow", locale: locale))
        #expect(detail.style == .groupedBars)
        #expect(detail.series.map(\.values) == [[7400], [5650]])
        // Income plus expenses isn't a number anyone wants.
        #expect(detail.readoutValue(at: 0) == nil)
        #expect(!detail.canHideSeries)
        #expect(CashFlowData(points: []).chartDetail(name: "", locale: locale) == nil)
    }

    @Test func ageOfMoneyIsMeasuredInDays() throws {
        let data = AgeOfMoneyData(currentAge: 42, points: [.init(monthLabel: "Oct 2026", age: 41), .init(monthLabel: "Nov 2026", age: 42)],
                                  trend: .up, insufficientData: false)
        let detail = try #require(data.chartDetail(name: "Age of Money"))
        #expect(detail.unit == .days)
        #expect(detail.series.map(\.values) == [[41, 42]])
        #expect(AgeOfMoneyData.empty.chartDetail(name: "") == nil)
    }

    @Test func budgetAnalysisComparesBudgetedWithSpendingAsMagnitudes() throws {
        func data(balanceOnly: Bool) -> BudgetAnalysisData {
            BudgetAnalysisData(
                intervalData: [.init(month: 202_610, budgetedCents: 560_000, spentCents: -565_000, balanceCents: -5000,
                                     overspendingAdjustmentCents: 0)],
                totalBudgetedCents: 560_000, totalSpentCents: -565_000, graphType: .bar, showBalance: false, balanceOnly: balanceOnly
            )
        }
        let detail = try #require(data(balanceOnly: false).chartDetail(name: "Budget", locale: locale))
        #expect(detail.intervals == ["Oct 26"])
        #expect(detail.series.map(\.values) == [[5600], [5650]])
        #expect(detail.readoutValue(at: 0) == nil)

        let balance = try #require(data(balanceOnly: true).chartDetail(name: "Budget", locale: locale))
        #expect(balance.series.map(\.values) == [[-50]])
    }

    @Test func forecastAndProjectionTurnDashedWhereTheyStart() throws {
        let forecast = BalanceForecastData(points: [
            .init(date: utc(2026, 11, 1), balanceCents: 500_000, isForecast: false),
            .init(date: utc(2026, 11, 8), balanceCents: 430_000, isForecast: false),
            .init(date: utc(2026, 11, 15), balanceCents: 350_000, isForecast: true),
        ])
        let detail = try #require(forecast.chartDetail(name: "Forecast", locale: locale))
        #expect(detail.series[0].dashedFrom == 2)
        #expect(detail.readoutValue(at: 2) == 3500)

        func point(_ month: Int, income: Int, projected: Bool) -> CrossoverPoint {
            CrossoverPoint(month: utc(2026, month), investmentIncomeCents: income, expensesCents: 350_000, nestEggCents: 0,
                           adjustedExpensesCents: nil, isProjection: projected)
        }
        let crossover = CrossoverData(
            points: [point(10, income: 290_000, projected: false), point(11, income: 310_000, projected: false),
                     point(12, income: 335_000, projected: true)],
            crossoverMonth: nil, lastKnownBalanceCents: 0, lastKnownMonthlyIncomeCents: 0, lastKnownMonthlyExpensesCents: 0,
            historicalReturn: nil, yearsToRetire: nil, targetMonthlyIncomeCents: nil, targetNestEggCents: nil
        )
        let lines = try #require(crossover.chartDetail(name: "Crossover", locale: locale))
        #expect(lines.series.map(\.dashedFrom) == [2, 2])
        #expect(lines.series.map(\.values) == [[2900, 3100, 3350], [3500, 3500, 3500]])
        #expect(CrossoverData.empty.chartDetail(name: "", locale: locale) == nil)
    }

    @Test func monteCarloLeadsWithTheMedianByAge() throws {
        func band(_ year: Int, _ p10: Int, _ p50: Int, _ p90: Int) -> MonteCarloPercentileBand {
            MonteCarloPercentileBand(year: year, p5: 0, p10: p10, p25: 0, p30: 0, p50: p50, p70: 0, p75: 0, p90: p90)
        }
        let data = MonteCarloData(successRate: 0.87, currentAge: 45, horizonYears: 2, simulationCount: 1000,
                                  percentileBands: [band(0, 100, 100, 100), band(1, 90, 120, 150)])
        let detail = try #require(data.chartDetail(name: "Outlook", locale: locale))
        #expect(detail.intervals == ["45", "46"])
        #expect(detail.series.map(\.name) == ["Median", "p90", "p10"])
        #expect(detail.readoutValue(at: 1) == 1.2)
    }

    // MARK: - Time range

    @Test func rangeIsThatManyMonthsEndingThisMonth() {
        let today = utc(2026, 11, 13)
        let calendar = Calendar(identifier: .gregorian)
        for (range, start) in [(ReportDetailRange.threeMonths, utc(2026, 9)), (.sixMonths, utc(2026, 6)), (.year, utc(2025, 12))] {
            let (from, to) = TimeFrame.resolve(range.timeFrame(asOf: today), asOf: today)
            #expect(from == start)
            // Through the end of November.
            #expect(calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: to).month == 11)
            #expect(calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: to).day == 30)
        }
    }

    @Test func rangingAMetaReplacesOnlyItsTimeFrame() {
        let meta = NetWorthMeta(name: "Net Worth", timeFrame: WidgetTimeFrame(start: "2020-01", end: "2020-02", mode: .static),
                                conditions: nil, conditionsOp: "and", interval: .monthly, mode: .stacked)
        let ranged = meta.ranged(.sixMonths, asOf: utc(2026, 11, 13))
        #expect(ranged.timeFrame == WidgetTimeFrame(start: "2026-06", end: "2026-11", mode: .slidingWindow))
        #expect(ranged.name == "Net Worth")
        #expect(ranged.conditionsOp == "and")
        #expect(ranged.interval == .monthly)
        #expect(ranged.mode == .stacked)
    }

    @Test(arguments: ReportDetailRange.allCases)
    func rangingACustomReportUsesANamedRangeTheEngineKnows(range: ReportDetailRange) {
        let today = utc(2026, 11, 13)
        // An unknown name falls through to "All time", which starts at `earliest`.
        let earliest = utc(2000, 1)
        let (start, _) = ReportDateRange.resolve(
            dateRange: range.customReportDateRange, dateStatic: false, startDate: nil, endDate: nil,
            includeCurrent: true, earliest: earliest, latest: today, today: today, firstDayOfWeekIdx: 0
        )
        #expect(start > earliest)
    }

    // MARK: - Sankey

    @Test func sankeyLayersBecomeRankedSections() {
        func node(_ name: String, _ layer: SankeyLayer, key: String? = nil) -> SankeyData.Node {
            .init(key: key ?? name, name: name, percentageLabel: "", layer: layer, isNegative: false)
        }
        let data = SankeyData(
            nodes: [
                node("Salary", .incomeCategory), // 0
                node("Interest", .incomeCategory), // 1
                node("Budget", .budget), // 2
                node("Food", .categoryGroup), // 3
                node("Bills", .categoryGroup), // 4
                node("Spacer", .categoryGroup, key: "x__HIDDEN"), // 5
                node("Unused", .category), // 6
            ],
            links: [
                .init(source: 0, target: 2, value: 7000),
                .init(source: 1, target: 2, value: 200),
                .init(source: 2, target: 3, value: 1500),
                .init(source: 2, target: 4, value: 2400),
                .init(source: 2, target: 5, value: -1),
            ],
            showPercentages: false
        )
        let sections = data.detailSections
        // Layers in diagram order; the empty category layer is dropped.
        #expect(sections.map(\.layer) == [.incomeCategory, .budget, .categoryGroup])
        #expect(sections[0].rows.map(\.name) == ["Salary", "Interest"])
        // The middle node shows what flows through it, not in + out.
        #expect(sections[1].rows.map(\.cents) == [7200])
        // Largest first, scaffolding left out.
        #expect(sections[2].rows.map(\.name) == ["Bills", "Food"])
        #expect(sections[2].rows.map(\.cents) == [2400, 1500])
        #expect(SankeyData.empty.detailSections.isEmpty)
    }

    // MARK: - Calendar

    private var november: Date {
        utc(2026, 11)
    }

    private func month(_ start: Date, active: [Int: (income: Int, expense: Int)]) -> CalendarMonthData {
        // One padding cell, then days 1...5.
        let days = [CalendarDayCell(dayOfMonth: nil, incomeCents: 0, expenseCents: 0, incomeSize: 0, expenseSize: 0)]
            + (1...5).map { day in
                CalendarDayCell(dayOfMonth: day, incomeCents: active[day]?.income ?? 0,
                                expenseCents: active[day]?.expense ?? 0, incomeSize: 0, expenseSize: 0)
            }
        return CalendarMonthData(monthStart: start, days: days, totalIncomeCents: 0, totalExpenseCents: 0)
    }

    @Test func calendarReadoutStartsOnTheLatestDayWithActivity() {
        let quiet = month(november, active: [:])
        let busy = month(november, active: [2: (0, 500), 4: (900, 0)])
        func data(_ months: [CalendarMonthData]) -> CalendarData {
            CalendarData(months: months, totalIncomeCents: 0, totalExpenseCents: 0, firstDayOfWeekIdx: 0)
        }
        // Day 4 sits at cell 4 (after the padding cell).
        #expect(data([busy]).latestActiveDay == .init(month: 0, cell: 4))
        // A newer month with nothing in it is skipped.
        #expect(data([busy, quiet]).latestActiveDay == .init(month: 0, cell: 4))
        #expect(data([quiet, busy]).latestActiveDay == .init(month: 1, cell: 4))
        #expect(data([quiet]).latestActiveDay == nil)
        #expect(data([]).latestActiveDay == nil)
    }

    @Test func calendarDayTitleCountsFromTheMonthStartInUTC() {
        #expect(CalendarWidgetFormatting.dayTitle(monthStart: november, day: 1, locale: locale) == "Sunday, November 1, 2026")
        #expect(CalendarWidgetFormatting.dayTitle(monthStart: november, day: 13, locale: locale) == "Friday, November 13, 2026")
    }

    // MARK: - Pages render

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: NavigationStack { view }.environmentObject(BudgetStore.previewInstance()))
            .sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    @Test func detailPagesLayOut() throws {
        let chart = try #require(report(.stacked(stacked)).chartDetail)
        #expect(height(ReportChartDetailView(detail: chart)) > 0)
        // With the range picker on top, as the dashboard hosts it.
        #expect(height(ReportRangedDetail(initial: chart, transactions: [], recompute: { _, _ in chart }) {
            ReportChartDetailView(detail: $0)
        }) > 0)
        #expect(height(SankeyDetailView(displayName: "Flow", data: .empty)) > 0)
        let calendar = CalendarData(months: [month(november, active: [2: (0, 500)])],
                                    totalIncomeCents: 0, totalExpenseCents: 500, firstDayOfWeekIdx: 0)
        #expect(height(CalendarDetailView(displayName: "Calendar", data: calendar)) > 0)
    }
}
