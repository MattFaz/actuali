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
        let stackedDetail = try #require(report(.stacked(stacked)).chartDetail())
        #expect(stackedDetail.style == .stackedBars)
        #expect(stackedDetail.intervals == ["Jan", "Feb", "Mar"])
        #expect(stackedDetail.series.map(\.name) == ["Brokerage", "401(k)", "HSA"])
        #expect(stackedDetail.series.map(\.values) == stacked.values)
        #expect(stackedDetail.canHideSeries)
        #expect(report(.lines(stacked, trends: [])).chartDetail()?.style == .lines)

        let bars = [CustomReportData.Bar(label: "Jan", valueUnits: 5), .init(label: "Feb", valueUnits: -7)]
        let signed = try #require(report(.bars(bars, signed: true)).chartDetail())
        #expect(signed.signed)
        #expect(signed.series.map(\.values) == [[5, -7]])
        // One series: nothing to switch off.
        #expect(!signed.canHideSeries)
        // Bars are amounts per interval, so the range has a total.
        #expect(signed.stats == [.init(label: "Total", value: .amount(-2))])
        #expect(stackedDetail.stats.isEmpty)
        #expect(report(.area(bars)).chartDetail()?.style == .area)
    }

    @Test func reportsWithoutIntervalsAreBreakdownsNotCharts() {
        let donut = report(.donut(slices: [.init(label: "Rent", valueUnits: 1, group: nil)], groups: []))
        #expect(donut.chartDetail() == nil)
        #expect(donut.breakdown != nil)
        let table = report(.table([.init(name: "Rent", totalUnits: 1)], totalUnits: 1))
        #expect(table.chartDetail() == nil)
        #expect(table.breakdown != nil)
        #expect(report(.unsupported("nope")).chartDetail() == nil)
        #expect(report(.unsupported("nope")).breakdown == nil)
        // Nothing to list, and a chart is not a breakdown.
        #expect(report(.donut(slices: [], groups: [])).breakdown == nil)
        #expect(report(.table([], totalUnits: 0)).breakdown == nil)
        #expect(report(.stacked(stacked)).breakdown == nil)
        // Nothing to scrub through.
        #expect(report(.bars([], signed: false)).chartDetail() == nil)
        #expect(report(.stacked(.init(intervalLabels: ["Jan"], seriesNames: [], values: []))).chartDetail() == nil)
    }

    @Test func oneRingDonutListsEverySliceWithItsShare() throws {
        let slices = [CustomReportData.Slice(label: "Rent", valueUnits: 300, group: nil), .init(label: "Food", valueUnits: 100, group: nil)]
        let breakdown = try #require(report(.donut(slices: slices, groups: [])).breakdown)
        #expect(breakdown.rows.map(\.name) == ["Rent", "Food"])
        #expect(breakdown.total == 400)
        #expect(breakdown.share(of: breakdown.rows[0]) == 0.75)
        // The colours the donut draws them in.
        #expect(breakdown.rows.map(\.color) == ReportDonutChart.sliceColors(slices, groups: []))
        #expect(breakdown.rows.flatMap(\.children).isEmpty)
        #expect(breakdown.donut == .init(slices: slices, groups: []))
    }

    @Test func twoRingDonutListsGroupsOverTheirCategories() throws {
        let slices = [CustomReportData.Slice(label: "Rent", valueUnits: 300, group: 0), .init(label: "Food", valueUnits: 60, group: 1),
                      .init(label: "Power", valueUnits: 40, group: 0)]
        let groups = [CustomReportData.Bar(label: "Home", valueUnits: 340), .init(label: "Daily", valueUnits: 60)]
        let breakdown = try #require(report(.donut(slices: slices, groups: groups)).breakdown)
        #expect(breakdown.rows.map(\.name) == ["Home", "Daily"])
        #expect(breakdown.rows.map { $0.children.map(\.name) } == [["Rent", "Power"], ["Food"]])
        #expect(breakdown.total == 400)
    }

    @Test func tableIsRankedByMagnitudeAndKeepsTheReportsTotal() throws {
        let rows = [CustomReportData.TableRow(name: "Small", totalUnits: 5), .init(name: "Refund", totalUnits: -40), .init(name: "Big", totalUnits: 20)]
        let breakdown = try #require(report(.table(rows, totalUnits: -15)).breakdown)
        #expect(breakdown.rows.map(\.name) == ["Refund", "Big", "Small"])
        #expect(breakdown.total == -15)
        #expect(breakdown.donut == nil)
        // A card names the largest few, in the list's order.
        #expect(breakdown.leadingRows(limit: 2) == [0, 1])
        #expect(ReportBreakdown(name: "", rows: breakdown.rows, total: 0).share(of: breakdown.rows[0]) == nil)
    }

    @Test func stackedBarsCanBeReadAsOneTotalPerInterval() throws {
        let detail = try #require(report(.stacked(stacked)).chartDetail())
        #expect(detail.canShowTotal)
        let total = detail.totalled()
        #expect(total.series.map(\.values) == [[111, -178, 333]])
        // It dips below zero, so the bars read by sign.
        #expect(total.signed)
        // Hidden series stay out of the sum.
        let withoutFirst = detail.totalled(hiding: [0])
        #expect(withoutFirst.series.map(\.values) == [[11, 22, 33]])
        #expect(!withoutFirst.signed)
        // Lines are levels, and one series is already its own total.
        #expect(report(.lines(stacked, trends: [])).chartDetail()?.canShowTotal == false)
        #expect(report(.bars([.init(label: "Jan", valueUnits: 5)], signed: false)).chartDetail()?.canShowTotal == false)
    }

    @Test func axisNamesMonthsOrYearsWhereTheyStart() {
        let locale = Locale(identifier: "en_US")
        func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        // Daily points: a label where each month begins, and on the first.
        #expect(ReportDetailLabels.axis([day(2026, 11, 29), day(2026, 11, 30), day(2026, 12, 1), day(2026, 12, 2)], locale: locale)
            == ["Nov", "", "Dec", ""])
        // More than a year of months: month names would repeat, so years.
        let months = (0..<26).map { day(2026 + $0 / 12, 1 + $0 % 12, 1) }
        let labels = ReportDetailLabels.axis(months, locale: locale)
        #expect(labels.filter { !$0.isEmpty } == ["2027", "2028"])
        #expect(labels[12] == "2027")
    }

    @Test func monthlyCustomReportsNameMonthsOnTheAxisLikeTheOtherWidgets() throws {
        func detail(_ labels: [String]) throws -> ReportChartDetail {
            let stacked = CustomReportData.Stacked(intervalLabels: labels, seriesNames: ["A"], values: [labels.map { _ in 1 }])
            return try #require(CustomReportData(name: "R", rangeLabel: "Last 2 months", kind: .stacked(stacked))
                .chartDetail(locale: Locale(identifier: "en_US")))
        }
        let monthly = try detail(["Dec '26", "Jan '27"])
        #expect(monthly.axisLabels == ["Dec", "Jan"])
        // The report's own caption still leads the page.
        #expect(monthly.rangeCaption == "Last 2 months")
        // Daily and weekly labels are dates too: a month where one starts.
        #expect(try detail(["26-11-30", "26-12-01", "26-12-02"]).axisLabels == ["Nov", "Dec", ""])
        // Years are already short.
        #expect(try detail(["2025", "2026"]).axisLabels == nil)
    }

    @Test func axisTicksAreThinnedFromTheFirst() {
        #expect(ReportDetailChart.ticks([]) == [])
        #expect(ReportDetailChart.ticks(["Jan", "", "Feb", ""]) == [0, 2])
        // Twelve months: every other one.
        #expect(ReportDetailChart.ticks((1...12).map { "m\($0)" }) == [0, 2, 4, 6, 8, 10])
        #expect(ReportDetailChart.ticks((1...56).map { "\($0)" }).count <= 6)
    }

    @Test func selectionDotsStopWhenLinesCrowd() {
        #expect(ReportDetailChart.dotsSelection(series: 3))
        #expect(!ReportDetailChart.dotsSelection(series: 13))
    }

    @Test func sparseLinesGetADotOnEveryPoint() {
        #expect(ReportDetailChart.marksEveryPoint(intervals: 12, series: 1))
        #expect(!ReportDetailChart.marksEveryPoint(intervals: 90, series: 1))
        #expect(!ReportDetailChart.marksEveryPoint(intervals: 6, series: 13))
    }

    @Test func scrubbingALineSnapsToTheNearestInterval() {
        let months = ["Jan", "Feb", "Mar"]
        #expect(ReportDetailChart.interval(at: 0.4, in: months) == "Jan")
        #expect(ReportDetailChart.interval(at: 1.6, in: months) == "Mar")
        // The scale runs a little past both ends.
        #expect(ReportDetailChart.interval(at: -0.2, in: months) == "Jan")
        #expect(ReportDetailChart.interval(at: 2.3, in: months) == "Mar")
        #expect(ReportDetailChart.interval(at: 0, in: []) == nil)
    }

    @Test func repeatedLabelsAreNotChartable() {
        // A string axis merges equal labels into one position.
        let bars = [CustomReportData.Bar(label: "Rent", valueUnits: 5), .init(label: "Rent", valueUnits: 7)]
        #expect(report(.bars(bars, signed: false)).chartDetail() == nil)
    }

    @Test func readoutFollowsTheChartsMeaning() throws {
        let total = try #require(report(.stacked(stacked)).chartDetail())
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

        var difference = total
        difference.readout = .difference
        #expect(difference.readoutValue(at: 1) == -220)
        // Three series that can't be switched off sit beside the headline; four go in a list.
        #expect(difference.showsInlineLegend)
        difference.series.append(difference.series[0])
        #expect(!difference.showsInlineLegend)
    }

    @Test func trendLinesCarryOverOnlyWhenTheReportHasThem() throws {
        let trends = [CustomReportData.Trend(startUnits: 1, endUnits: 2), .init(startUnits: 3, endUnits: 4), .init(startUnits: 5, endUnits: 6)]
        let with = try #require(report(.lines(stacked, trends: trends)).chartDetail())
        #expect(with.series.map(\.trend) == trends)
        let without = try #require(report(.lines(stacked, trends: [])).chartDetail())
        #expect(without.series.allSatisfy { $0.trend == nil })
    }

    @Test func cardNamesTheLargestSeriesInLegendOrder() throws {
        // Latest interval: 300, 30, 3, -900. Largest by magnitude, kept in legend order.
        let table = CustomReportData.Stacked(
            intervalLabels: ["Jan", "Feb"],
            seriesNames: ["A", "B", "C", "D"],
            values: [[0, 300], [0, 30], [0, 3], [0, -900]]
        )
        let detail = try #require(report(.stacked(table)).chartDetail())
        #expect(detail.leadingSeries(limit: 3) == [0, 1, 3])
        #expect(detail.leadingSeries(limit: 1) == [3])
        #expect(detail.leadingSeries(limit: 10) == [0, 1, 2, 3])
    }

    @Test func glanceCardStaysCompactHoweverManySeries() throws {
        let many = CustomReportData.Stacked(
            intervalLabels: ["Jan", "Feb", "Mar"],
            seriesNames: (0..<12).map { "Investment account number \($0)" },
            values: Array(repeating: [100, 200, 300], count: 12)
        )
        func height(_ view: some View) -> CGFloat {
            UIHostingController(rootView: view.environmentObject(BudgetStore.previewInstance()))
                .sizeThatFits(in: CGSize(width: 390, height: 4000)).height
        }
        let glance = try height(ReportGlanceCard(detail: #require(report(.stacked(many)).chartDetail())))
        // Three named series and a count, rather than twelve legend entries.
        #expect(glance < height(CustomReportWidgetView(data: report(.stacked(many)))))
        // And no taller for twelve series than for four.
        let four = CustomReportData.Stacked(intervalLabels: many.intervalLabels, seriesNames: Array(many.seriesNames.prefix(4)),
                                            values: Array(many.values.prefix(4)))
        #expect(try glance == height(ReportGlanceCard(detail: #require(report(.stacked(four)).chartDetail()))))
    }

    @Test func cardsLeadWithTheNumberThatAnswersTheWidget() throws {
        // A forecast: how low the balance gets, and when.
        let forecast = BalanceForecastData(points: [
            .init(date: utc(2026, 11, 1), balanceCents: 500_000, isForecast: false),
            .init(date: utc(2026, 11, 8), balanceCents: 100_000, isForecast: false),
            .init(date: utc(2026, 11, 15), balanceCents: 350_000, isForecast: true),
            .init(date: utc(2026, 11, 22), balanceCents: 240_000, isForecast: true),
            .init(date: utc(2026, 11, 29), balanceCents: 410_000, isForecast: true),
        ])
        let forecastCard = try #require(forecast.chartDetail(name: "Forecast", locale: locale)).card
        // The lowest forecast point, not the lower one already in the past.
        #expect(forecastCard.value == 2400)
        #expect(forecastCard.context == "Low · Nov 22, 2026")

        // A balance: its change across the range.
        let netWorth = NetWorthData(points: [.init(date: utc(2026, 10), balanceCents: 1), .init(date: utc(2026, 11), balanceCents: 2)])
        #expect(try #require(netWorth.chartDetail(name: "", locale: locale)).card.showsChange)

        // A simulation: its success rate, which isn't an amount.
        func band(_ year: Int) -> MonteCarloPercentileBand {
            MonteCarloPercentileBand(year: year, p5: 0, p10: 0, p25: 0, p30: 0, p50: 0, p70: 0, p75: 0, p90: 0)
        }
        let monteCarlo = MonteCarloData(successRate: 0.364, currentAge: 45, horizonYears: 1, simulationCount: 10,
                                        percentileBands: [band(0), band(1)])
        let monteCarloCard = try #require(monteCarlo.chartDetail(name: "", locale: locale)).card
        #expect(monteCarloCard.text == "36.4%")
        #expect(monteCarloCard.context == "Success rate")
    }

    // MARK: - Spending

    @Test func spendingComparisonsCoverEveryModeAndKeepTheConfiguredOneForTheCard() {
        let meta = SpendingMeta(name: "Spending", conditions: nil, conditionsOp: "and", compare: nil, compareTo: "2026-10",
                                isLive: true, mode: .budget, averageRange: nil)
        var seen: [SpendingMeta] = []
        let comparisons = SpendingComparisons.compute(meta: meta) { meta in
            seen.append(meta)
            return SpendingData(currentSpentCents: 100, comparisonCents: meta.mode == .budget ? 250 : 50)
        }
        #expect(seen.map(\.mode) == [.singleMonth, .budget, .average])
        // Only the mode changes.
        #expect(seen.allSatisfy { $0.compareTo == "2026-10" && $0.conditionsOp == "and" && $0.isLive == true })
        #expect(comparisons.configured == .budget)
        #expect(comparisons.card.comparisonCents == 250)

        // No meta: upstream's default is single-month.
        let fallback = SpendingComparisons.compute(meta: nil) { _ in SpendingData(currentSpentCents: 1, comparisonCents: 2) }
        #expect(fallback.configured == .singleMonth)
        #expect(fallback.byMode.count == 3)
    }

    // MARK: - Dashboard rows

    @Test func singleNumberWidgetsPairUpOnlyWithANeighbour() {
        let summary = DashboardWidget.summary(id: "s", meta: nil)
        let formula = DashboardWidget.formula(id: "f", meta: nil)
        let chart = DashboardWidget.netWorth(id: "n", meta: nil)
        func shape(_ widgets: [DashboardWidget]) -> [Int] {
            DashboardView.rows(widgets).map(\.count)
        }
        #expect(shape([summary, formula, chart]) == [2, 1])
        // A third in a run starts a new row.
        #expect(shape([summary, formula, summary, chart]) == [2, 1, 1])
        #expect(shape([summary, summary, summary, summary]) == [2, 2])
        // Split by a chart: no pairing across it.
        #expect(shape([summary, chart, formula]) == [1, 1, 1])
        #expect(shape([chart, chart]) == [1, 1])
        #expect(shape([]) == [])
        // Order is preserved.
        #expect(DashboardView.rows([summary, formula, chart]).flatMap(\.self).map(\.id) == ["s", "f", "n"])
    }

    // MARK: - Other chart widgets

    private let locale = Locale(identifier: "en_US")

    private func utc(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
        var components = DateComponents(); components.year = year; components.month = month; components.day = day
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test func dateLabelsShowTheDayOnlyWhenSomeDateNeedsIt() {
        #expect(ReportDetailLabels.dates([utc(2026, 10), utc(2026, 11)], locale: locale) == ["Oct '26", "Nov '26"])
        #expect(ReportDetailLabels.dates([utc(2026, 11, 1), utc(2026, 11, 13)], locale: locale) == ["Nov 1, 2026", "Nov 13, 2026"])
        #expect(ReportDetailLabels.dates(ReportDetailLabels.monthDates([202_512, 202_601]), locale: locale) == ["Dec '25", "Jan '26"])
    }

    @Test func netWorthIsOneAreaSeries() throws {
        let data = NetWorthData(points: [.init(date: utc(2026, 10), balanceCents: 100_000), .init(date: utc(2026, 11), balanceCents: 125_050)])
        let detail = try #require(data.chartDetail(name: "Net Worth", locale: locale))
        #expect(detail.style == .area)
        #expect(detail.intervals == ["Oct '26", "Nov '26"])
        // The axis names the months; the dates they span lead the page.
        #expect(detail.axisLabels == ["Oct", "Nov"])
        #expect(detail.rangeCaption == "Oct '26 – Nov '26")
        #expect(detail.series.map(\.values) == [[1000, 1250.5]])
        #expect(detail.readoutValue(at: 1) == 1250.5)
        // A balance is a level, so the range is summed up as change, high and low.
        #expect(detail.stats.map(\.value) == [.amount(250.5), .amount(1250.5), .amount(1000)])
        // A single point has no trend to open.
        #expect(NetWorthData(points: [.init(date: utc(2026, 11), balanceCents: 1)]).chartDetail(name: "", locale: locale) == nil)
    }

    @Test func cashFlowPairsIncomeAndExpensesWithoutAHeadlineSum() throws {
        let data = CashFlowData(points: [.init(periodStart: utc(2026, 10), incomeCents: 740_000, expenseCents: 565_000)])
        let detail = try #require(data.chartDetail(name: "Cash Flow", locale: locale))
        #expect(detail.style == .groupedBars)
        #expect(detail.series.map(\.values) == [[7400], [5650]])
        // The headline is what's left, not income plus expenses.
        #expect(detail.readoutValue(at: 0) == 1750)
        #expect(detail.readoutLabel == "Net")
        #expect(!detail.canHideSeries)
        // Two series: their values sit beside the headline, not in a list.
        #expect(detail.showsInlineLegend)
        #expect(detail.stats.map(\.value) == [.amount(7400), .amount(5650), .amount(1750)])
        #expect(CashFlowData(points: []).chartDetail(name: "", locale: locale) == nil)
    }

    @Test func ageOfMoneyIsMeasuredInDays() throws {
        let data = AgeOfMoneyData(currentAge: 42, points: [.init(month: utc(2026, 10), monthLabel: "Oct 2026", age: 41),
                                                           .init(month: utc(2026, 11), monthLabel: "Nov 2026", age: 42)],
                                  trend: .up, insufficientData: false)
        let detail = try #require(data.chartDetail(name: "Age of Money", locale: locale))
        #expect(detail.unit == .days)
        // Dated like the other widgets, not with the card's "Oct 2026".
        #expect(detail.intervals == ["Oct '26", "Nov '26"])
        #expect(detail.axisLabels == ["Oct", "Nov"])
        #expect(detail.series.map(\.values) == [[41, 42]])
        #expect(AgeOfMoneyData.empty.chartDetail(name: "", locale: locale) == nil)
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
        #expect(detail.intervals == ["Oct '26"])
        #expect(detail.series.map(\.values) == [[5600], [5650]])
        // Budgeted less spent: over budget is negative.
        #expect(detail.readoutValue(at: 0) == -50)

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
        #expect(detail.events.isEmpty)

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
        // Nothing projected to cross: no stats to show.
        #expect(lines.stats.isEmpty)
        #expect(CrossoverData.empty.chartDetail(name: "", locale: locale) == nil)
    }

    @Test func forecastListsTheNextScheduledOccurrences() throws {
        var forecast = BalanceForecastData(points: [
            .init(date: utc(2026, 11, 1), balanceCents: 500_000, isForecast: false),
            .init(date: utc(2026, 12, 1), balanceCents: 300_000, isForecast: true),
        ])
        forecast.upcoming = [
            .init(scheduleName: "Rent", payeeId: "p1", date: utc(2026, 12, 1), amountCents: -185_000),
            .init(scheduleName: nil, payeeId: "p2", date: utc(2026, 12, 11), amountCents: -2299),
            .init(scheduleName: nil, payeeId: nil, date: utc(2026, 12, 20), amountCents: 100),
        ] + (1...10).map { .init(scheduleName: "Later", payeeId: nil, date: utc(2027, 1, $0), amountCents: -1) }
        let detail = try #require(forecast.chartDetail(name: "Forecast", payeeNames: ["p2": "Netflix"], locale: locale))
        #expect(detail.events.count == BalanceForecastData.upcomingLimit)
        // A schedule's name, else its payee, else just "Schedule".
        #expect(detail.events.prefix(3).map(\.name) == ["Rent", "Netflix", "Schedule"])
        // The day shows even when an occurrence falls on the 1st.
        #expect(detail.events.prefix(2).map(\.date) == ["Dec 1, 2026", "Dec 11, 2026"])
        #expect(detail.events[0].amount == -1850)
    }

    @Test func monteCarloLeadsWithTheMedianByAge() throws {
        func band(_ year: Int, _ p10: Int, _ p50: Int, _ p90: Int) -> MonteCarloPercentileBand {
            MonteCarloPercentileBand(year: year, p5: 0, p10: p10, p25: 0, p30: 0, p50: p50, p70: 0, p75: 0, p90: p90)
        }
        let data = MonteCarloData(successRate: 0.87, currentAge: 45, horizonYears: 2, simulationCount: 1000,
                                  percentileBands: [band(0, 100, 100, 100), band(1, 90, 120, 150)])
        let detail = try #require(data.chartDetail(name: "Outlook", locale: locale))
        #expect(detail.intervals == ["45", "46"])
        // The median is the line; p10 to p90 is a shaded band behind it.
        #expect(detail.series.map(\.name) == ["Median"])
        #expect(detail.band?.lower == [1, 0.9])
        #expect(detail.band?.upper == [1, 1.5])
        #expect(detail.readoutValue(at: 1) == 1.2)
        #expect(detail.readoutLabel == "Median")
        #expect(detail.compact)
        #expect(detail.stats.map(\.value) == [.text("87%"), .text("1,000")])
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
        let chart = try #require(report(.stacked(stacked)).chartDetail())
        #expect(height(ReportChartDetailView(detail: chart)) > 0)
        // With the range picker on top, as the dashboard hosts it.
        #expect(height(ReportRangedDetail(initial: chart, transactions: [], recompute: { _, _ in chart }) {
            ReportChartDetailView(detail: $0)
        }) > 0)
        #expect(height(SankeyDetailView(displayName: "Flow", data: .empty)) > 0)
        let donut = try #require(report(.donut(slices: [.init(label: "Rent", valueUnits: 300, group: 0)],
                                               groups: [.init(label: "Home", valueUnits: 300)])).breakdown)
        #expect(height(ReportBreakdownDetailView(breakdown: donut)) > 0)
        let table = try #require(report(.table([.init(name: "Rent", totalUnits: 300)], totalUnits: 300)).breakdown)
        #expect(height(ReportBreakdownDetailView(breakdown: table)) > 0)
        let spending = SpendingComparisons.compute(meta: nil) { _ in SpendingData(currentSpentCents: 100, comparisonCents: 150) }
        #expect(height(SpendingDetailView(displayName: "Spending", comparisons: spending, labels: ["a", "b", "c"])) > 0)
        let calendar = CalendarData(months: [month(november, active: [2: (0, 500)])],
                                    totalIncomeCents: 0, totalExpenseCents: 500, firstDayOfWeekIdx: 0)
        #expect(height(CalendarDetailView(displayName: "Calendar", data: calendar)) > 0)
    }
}
