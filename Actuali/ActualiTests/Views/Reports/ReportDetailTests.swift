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

    @Test func chartKindsWithIntervalsGetADetailTable() {
        #expect(report(.stacked(stacked)).detailTable == stacked)
        #expect(report(.lines(stacked, trends: [])).detailTable == stacked)

        let bars = [CustomReportData.Bar(label: "Jan", valueUnits: 5), .init(label: "Feb", valueUnits: -7)]
        let single = CustomReportData.Stacked(intervalLabels: ["Jan", "Feb"], seriesNames: ["Report"], values: [[5, -7]])
        #expect(report(.bars(bars, signed: true)).detailTable == single)
        #expect(report(.area(bars)).detailTable == single)
    }

    @Test func cardsThatAlreadyListEverythingHaveNoDetail() {
        #expect(report(.donut(slices: [.init(label: "Rent", valueUnits: 1, group: nil)], groups: [])).detailTable == nil)
        #expect(report(.table([.init(name: "Rent", totalUnits: 1)], totalUnits: 1)).detailTable == nil)
        #expect(report(.unsupported("nope")).detailTable == nil)
        // Nothing to scrub through.
        #expect(report(.bars([], signed: false)).detailTable == nil)
        #expect(report(.stacked(.init(intervalLabels: ["Jan"], seriesNames: [], values: []))).detailTable == nil)
    }

    @Test func totalsLeaveOutHiddenSeries() {
        #expect(stacked.totals(hiding: []) == [111, -178, 333])
        #expect(stacked.totals(hiding: [0]) == [11, 22, 33])
        #expect(stacked.totals(hiding: [0, 1, 2]) == [0, 0, 0])
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
        var components = DateComponents(); components.year = 2026; components.month = 11; components.day = 1
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
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
        let locale = Locale(identifier: "en_US")
        #expect(CalendarWidgetFormatting.dayTitle(monthStart: november, day: 1, locale: locale) == "Sunday, November 1, 2026")
        #expect(CalendarWidgetFormatting.dayTitle(monthStart: november, day: 13, locale: locale) == "Friday, November 13, 2026")
    }

    // MARK: - Pages render

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: NavigationStack { view }.environmentObject(BudgetStore.previewInstance()))
            .sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    @Test func detailPagesLayOut() {
        #expect(height(CustomReportDetailView(data: report(.stacked(stacked)), table: stacked)) > 0)
        #expect(height(SankeyDetailView(displayName: "Flow", data: .empty)) > 0)
        let calendar = CalendarData(months: [month(november, active: [2: (0, 500)])],
                                    totalIncomeCents: 0, totalExpenseCents: 500, firstDayOfWeekIdx: 0)
        #expect(height(CalendarDetailView(displayName: "Calendar", data: calendar)) > 0)
    }
}
