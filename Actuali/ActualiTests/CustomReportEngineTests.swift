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

    private func tx(_ id: String, date: Int, amount: Int, category: String?,
                    account: String = "a1") -> Transaction {
        Transaction(id: id, accountId: account, date: date, amount: amount,
                    payeeId: nil, payeeName: nil, categoryId: category, categoryName: nil,
                    notes: nil, cleared: true, reconciled: false, transferId: nil,
                    isParent: false, parentId: nil, tombstone: false,
                    sortOrder: nil, importedPayee: nil)
    }

    private func config(
        mode: String, groupBy: String, balance: String, interval: String,
        graph: String, sortBy: String = "desc",
        showOffBudget: Bool = false, showUncategorized: Bool = false
    ) -> CustomReportConfig {
        CustomReportConfig(
            id: "r", name: "Test", mode: mode, groupBy: groupBy, balanceType: balance,
            interval: interval, graphType: graph, dateRange: "All time", dateStatic: false,
            startDate: nil, endDate: nil, includeCurrent: true, showEmpty: false,
            showOffBudget: showOffBudget, showHidden: false, showUncategorized: showUncategorized,
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

    @Test func offBudgetMoneyLandsInSyntheticRowsConsistently() {
        // showOffBudget=true + showUncategorized=false: off-budget txs (even
        // categorized ones — upstream routes any off-budget tx to the
        // "Off budget" row) must appear in Category and Group outputs and the
        // totals must match the Interval output for the same config.
        var ctx = reportContext
        ctx.offBudgetAccountIds = ["a-off"]
        let txs = [
            tx("1", date: 20260601, amount: -10_000, category: "c-food"),                    // Food 100
            tx("2", date: 20260615, amount: -4_000,  category: nil,     account: "a-off"),   // off-budget 40
            tx("3", date: 20260620, amount: -1_000,  category: "c-fun", account: "a-off"),   // off-budget 10
        ]
        func run(groupBy: String) -> CustomReportData {
            CustomReportEngine.compute(
                config: config(mode: "total", groupBy: groupBy, balance: "Payment",
                               interval: "Monthly", graph: "BarGraph", sortBy: "budget",
                               showOffBudget: true),
                transactions: txs, reportContext: ctx, filterContext: .empty, today: today)
        }
        guard case .bars(let byCategory, _) = run(groupBy: "Category").kind,
              case .bars(let byGroup, _) = run(groupBy: "Group").kind,
              case .bars(let byInterval, _) = run(groupBy: "Interval").kind else {
            Issue.record("expected bars for all three groupings"); return
        }
        #expect(byCategory.map(\.label) == ["Food", "Off budget"])
        #expect(byCategory.map(\.valueUnits) == [100.0, 50.0])
        #expect(byGroup.map(\.label) == ["Living", "Uncategorized & Off budget"])
        #expect(byGroup.map(\.valueUnits) == [100.0, 50.0])
        let total = byInterval.map(\.valueUnits).reduce(0, +)
        #expect(total == 150.0)
        #expect(byCategory.map(\.valueUnits).reduce(0, +) == total)
        #expect(byGroup.map(\.valueUnits).reduce(0, +) == total)
    }

    @Test func danglingCategoryFallsBackToUncategorized() {
        // A categoryId missing from the context behaves like no category at
        // all (upstream joins through the categories table), so with
        // showUncategorized=true it lands in the "Uncategorized" row — and
        // in the combined group under groupBy Group. It never vanishes.
        let txs = [
            tx("1", date: 20260601, amount: -10_000, category: "c-food"),
            tx("2", date: 20260615, amount: -4_000,  category: "c-ghost"),  // dangling
        ]
        func run(groupBy: String) -> CustomReportData {
            CustomReportEngine.compute(
                config: config(mode: "total", groupBy: groupBy, balance: "Payment",
                               interval: "Monthly", graph: "BarGraph", sortBy: "budget",
                               showUncategorized: true),
                transactions: txs, reportContext: reportContext, filterContext: .empty, today: today)
        }
        guard case .bars(let byCategory, _) = run(groupBy: "Category").kind,
              case .bars(let byGroup, _) = run(groupBy: "Group").kind else {
            Issue.record("expected bars for both groupings"); return
        }
        #expect(byCategory.map(\.label) == ["Food", "Uncategorized"])
        #expect(byCategory.map(\.valueUnits) == [100.0, 40.0])
        #expect(byGroup.map(\.label) == ["Living", "Uncategorized & Off budget"])
        #expect(byGroup.map(\.valueUnits) == [100.0, 40.0])
    }

    @Test func intervalTableShowsIntervalRows() {
        let data = CustomReportEngine.compute(
            config: config(mode: "total", groupBy: "Interval", balance: "Net",
                           interval: "Monthly", graph: "TableGraph"),
            transactions: sampleTxs, reportContext: reportContext,
            filterContext: .empty, today: today)
        guard case .table(let rows) = data.kind else {
            Issue.record("expected table, got \(data.kind)"); return
        }
        #expect(rows.map(\.name) == ["Jun '26", "Jul '26"])
        #expect(rows.map(\.totalUnits) == [-300.0, -50.0])
    }
}
