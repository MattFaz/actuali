import Foundation
import Testing
@testable import Actuali

struct DashboardTransactionRangeTests {
    private let today = CanonicalDateParser.parse("2026-05-14")!

    @Test func combinesWidgetsAndExpandsToWholeMonths() {
        let widgets: [DashboardWidget] = [
            .summary(id: "s", meta: SummaryMeta(name: nil, timeFrame: nil,
                                                conditions: nil, conditionsOp: nil, content: nil)),
            .calendar(id: "c", meta: CalendarMeta(name: nil, conditions: nil, conditionsOp: nil,
                                                  timeFrame: WidgetTimeFrame(start: "2026-02-15", end: "2026-03-02", mode: .static))),
        ]
        #expect(DashboardView.transactionRange(widgets: widgets, today: today) == 20_260_201...20_260_531)
    }

    @Test func cumulativeAndHistoryDependentReportsKeepFullHistory() {
        let widgets: [DashboardWidget] = [
            .netWorth(id: "n", meta: nil), .ageOfMoney(id: "a", meta: nil),
            .budgetAnalysis(id: "b", meta: nil), .balanceForecast(id: "f", meta: nil),
            .spending(id: "s", meta: nil), .customReport(id: "c", meta: nil),
            .crossover(id: "x", meta: nil), .formula(id: "q", meta: nil),
        ]
        for widget in widgets {
            #expect(DashboardView.transactionRange(widgets: [widget], today: today) == nil)
        }
    }

    @Test func allTimePercentageDivisorKeepsFullHistory() {
        let meta = SummaryMeta(name: nil, timeFrame: nil, conditions: nil, conditionsOp: nil,
                               content: SummaryContent(type: "percentage", divisorConditions: nil,
                                                       divisorConditionsOp: nil, divisorAllTimeDateRange: true))
        #expect(DashboardView.transactionRange(widgets: [.summary(id: "s", meta: meta)], today: today) == nil)
    }

    @Test func reversedRangeFallsBackToFullHistory() {
        let meta = CashFlowMeta(name: nil, timeFrame: WidgetTimeFrame(start: "2026-06", end: "2026-01", mode: .static),
                                conditions: nil, conditionsOp: nil, showBalance: nil)
        #expect(DashboardView.transactionRange(widgets: [.cashFlow(id: "c", meta: meta)], today: today) == nil)
    }
}
