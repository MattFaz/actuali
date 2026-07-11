import Foundation
import Testing
@testable import Actuali

struct CustomReportEngineTests {
    private let today = { // 2026-07-11 UTC
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 7, day: 11))!
    }()

    // Two groups, two categories each; "Secret" hidden category for visibility tests.
    private var reportContext: CustomReportEngine.ReportContext {
        CustomReportEngine.ReportContext(
            categories: [
                Category(id: "c-food", name: "Food", groupId: "g-living", isIncome: false, hidden: false, sortOrder: 0),
                Category(id: "c-rent", name: "Rent", groupId: "g-living", isIncome: false, hidden: false, sortOrder: 1),
                Category(id: "c-fun", name: "Fun", groupId: "g-play", isIncome: false, hidden: false, sortOrder: 2),
                Category(id: "c-hidden", name: "Secret", groupId: "g-play", isIncome: false, hidden: true, sortOrder: 3),
            ],
            groups: [
                CategoryGroup(id: "g-living", name: "Living", isIncome: false, hidden: false, sortOrder: 0, categories: []),
                CategoryGroup(id: "g-play", name: "Play", isIncome: false, hidden: false, sortOrder: 1, categories: []),
            ],
            offBudgetAccountIds: [],
            firstDayOfWeekIdx: 0)
    }

    private func tx(_ id: String, date: Int, amount: Int, category: String?) -> Transaction {
        Transaction(id: id, accountId: "a1", date: date, amount: amount,
                    payeeId: nil, payeeName: nil, categoryId: category, categoryName: nil,
                    notes: nil, cleared: true, reconciled: false, transferId: nil,
                    isParent: false, parentId: nil, tombstone: false,
                    sortOrder: nil, importedPayee: nil)
    }

    private func config(
        mode: String, groupBy: String, balance: String, interval: String,
        graph: String, sortBy: String = "desc"
    ) -> CustomReportConfig {
        CustomReportConfig(
            id: "r", name: "Test", mode: mode, groupBy: groupBy, balanceType: balance,
            interval: interval, graphType: graph, dateRange: "All time", dateStatic: false,
            startDate: nil, endDate: nil, includeCurrent: true, showEmpty: false,
            showOffBudget: false, showHidden: false, showUncategorized: false,
            sortBy: sortBy, conditions: nil, conditionsOp: "and")
    }

    private var sampleTxs: [Transaction] {
        [
            tx("1", date: 20260601, amount: -10_000, category: "c-food"),   // Jun: food 100
            tx("2", date: 20260615, amount: -20_000, category: "c-rent"),   // Jun: rent 200
            tx("3", date: 20260701, amount: -5_000,  category: "c-fun"),    // Jul: fun 50
            tx("4", date: 20260702, amount: 30_000,  category: nil),        // Jul: income (uncat)
            tx("5", date: 20260703, amount: -1_000,  category: "c-hidden"), // hidden, dropped
        ]
    }

    @Test func categorySpendingBars() {
        // mode total, groupBy Category, Payment, BarGraph, sort name.
        let data = CustomReportEngine.compute(
            config: config(mode: "total", groupBy: "Category", balance: "Payment",
                           interval: "Monthly", graph: "BarGraph", sortBy: "name"),
            transactions: sampleTxs, reportContext: reportContext,
            filterContext: .empty, today: today)
        guard case .bars(let bars, let signed) = data.kind else {
            Issue.record("expected bars, got \(data.kind)"); return
        }
        #expect(signed == false)
        #expect(bars.map(\.label) == ["Food", "Fun", "Rent"])       // name sort
        #expect(bars.map(\.valueUnits) == [100.0, 50.0, 200.0])    // |debts|
    }

    @Test func savedLostBarsPerInterval() {
        // mode total, groupBy Interval, Net, BarGraph → signed monthly bars.
        // Net per interval includes ALL matching txs — the uncategorized
        // income row is dropped by showUncategorized=false, so Jul = -50.
        let data = CustomReportEngine.compute(
            config: config(mode: "total", groupBy: "Interval", balance: "Net",
                           interval: "Monthly", graph: "BarGraph"),
            transactions: sampleTxs, reportContext: reportContext,
            filterContext: .empty, today: today)
        guard case .bars(let bars, let signed) = data.kind else {
            Issue.record("expected bars, got \(data.kind)"); return
        }
        #expect(signed == true)
        #expect(bars.map(\.label) == ["Jun '26", "Jul '26"])
        #expect(bars.map(\.valueUnits) == [-300.0, -50.0])
    }

    @Test func monthlySpendStackedByGroup() {
        let data = CustomReportEngine.compute(
            config: config(mode: "time", groupBy: "Group", balance: "Payment",
                           interval: "Monthly", graph: "StackedBarGraph"),
            transactions: sampleTxs, reportContext: reportContext,
            filterContext: .empty, today: today)
        guard case .stacked(let s) = data.kind else {
            Issue.record("expected stacked, got \(data.kind)"); return
        }
        #expect(s.intervalLabels == ["Jun '26", "Jul '26"])
        #expect(s.seriesNames == ["Living", "Play"])   // desc by total: 300 vs 50
        #expect(s.values == [[300.0, 0.0], [0.0, 50.0]])
    }

    @Test func weeklyBucketsStartSunday() {
        // 2026-07-01 is a Wednesday → its Sunday week start is 2026-06-28.
        let data = CustomReportEngine.compute(
            config: config(mode: "time", groupBy: "Group", balance: "Payment",
                           interval: "Weekly", graph: "StackedBarGraph"),
            transactions: [tx("1", date: 20260701, amount: -5_000, category: "c-fun")],
            reportContext: reportContext, filterContext: .empty, today: today)
        guard case .stacked(let s) = data.kind else {
            Issue.record("expected stacked, got \(data.kind)"); return
        }
        #expect(s.intervalLabels == ["26-06-28"])
    }

    @Test func unsupportedOptionsAreNamed() {
        let donut = CustomReportEngine.compute(
            config: config(mode: "total", groupBy: "Category", balance: "Payment",
                           interval: "Monthly", graph: "DonutGraph"),
            transactions: [], reportContext: reportContext, filterContext: .empty, today: today)
        guard case .unsupported(let reason) = donut.kind else {
            Issue.record("expected unsupported, got \(donut.kind)"); return
        }
        #expect(reason.contains("DonutGraph"))

        let missing = CustomReportEngine.compute(
            config: nil, transactions: [], reportContext: reportContext,
            filterContext: .empty, today: today)
        guard case .unsupported = missing.kind else {
            Issue.record("expected unsupported for missing config"); return
        }
    }

    @Test func tableRowsShowGroupTotals() {
        let data = CustomReportEngine.compute(
            config: config(mode: "time", groupBy: "Category", balance: "Net",
                           interval: "Monthly", graph: "TableGraph", sortBy: "budget"),
            transactions: sampleTxs, reportContext: reportContext,
            filterContext: .empty, today: today)
        guard case .table(let rows) = data.kind else {
            Issue.record("expected table, got \(data.kind)"); return
        }
        // budget sort = context order: Food, Rent, Fun (hidden dropped, empty dropped)
        #expect(rows.map(\.name) == ["Food", "Rent", "Fun"])
        #expect(rows.map(\.totalUnits) == [-100.0, -200.0, -50.0])
    }
}
