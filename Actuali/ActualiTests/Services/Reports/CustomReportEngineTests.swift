import Foundation
import Testing
@testable import Actuali

struct CustomReportEngineTests {
    private let today = { // 2026-07-11 UTC
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 7, day: 11))!
    }()

    // Two expense groups, two categories each; "Secret" hidden category for
    // visibility tests; an income group so Budgeted can skip it. Payees and
    // accounts for the Payee/Account groupings.
    private var reportContext: CustomReportEngine.ReportContext {
        CustomReportEngine.ReportContext(
            categories: [
                Category(id: "c-food", name: "Food", groupId: "g-living", isIncome: false, hidden: false, sortOrder: 0),
                Category(id: "c-rent", name: "Rent", groupId: "g-living", isIncome: false, hidden: false, sortOrder: 1),
                Category(id: "c-fun", name: "Fun", groupId: "g-play", isIncome: false, hidden: false, sortOrder: 2),
                Category(id: "c-hidden", name: "Secret", groupId: "g-play", isIncome: false, hidden: true, sortOrder: 3),
                Category(id: "c-salary", name: "Salary", groupId: "g-income", isIncome: true, hidden: false, sortOrder: 4),
            ],
            groups: [
                CategoryGroup(id: "g-living", name: "Living", isIncome: false, hidden: false, sortOrder: 0, categories: []),
                CategoryGroup(id: "g-play", name: "Play", isIncome: false, hidden: false, sortOrder: 1, categories: []),
                CategoryGroup(id: "g-income", name: "Income", isIncome: true, hidden: false, sortOrder: 2, categories: []),
            ],
            offBudgetAccountIds: [],
            firstDayOfWeekIdx: 0,
            payees: [
                Payee(id: "p-store", name: "Store", transferAccountId: nil, tombstone: false),
                Payee(id: "p-xfer", name: "", transferAccountId: "a-savings", tombstone: false),
            ],
            accounts: [
                Account(id: "a1", name: "Checking", type: .checking, offBudget: false, closed: false, sortOrder: 0, balance: 0),
                Account(id: "a-savings", name: "Savings", type: .savings, offBudget: false, closed: false, sortOrder: 1, balance: 0),
                Account(id: "a-off", name: "Brokerage", type: .investment, offBudget: true, closed: false, sortOrder: 2, balance: 0),
            ])
    }

    private func tx(_ id: String, date: Int, amount: Int, category: String?,
                    account: String = "a1", payee: String? = nil) -> Transaction {
        Transaction(id: id, accountId: account, date: date, amount: amount,
                    payeeId: payee, payeeName: nil, categoryId: category, categoryName: nil,
                    notes: nil, cleared: true, reconciled: false, transferId: nil,
                    isParent: false, parentId: nil, tombstone: false,
                    sortOrder: nil, importedPayee: nil)
    }

    private func config(
        mode: String, groupBy: String, balance: String, interval: String,
        graph: String, sortBy: String = "desc",
        showEmpty: Bool = false, showOffBudget: Bool = false, showUncategorized: Bool = false,
        showTrendLines: Bool = false, trimIntervals: Bool = false,
        dateRange: String = "All time",
        staticRange: (start: String, end: String)? = nil,
        conditions: [WidgetRuleCondition]? = nil
    ) -> CustomReportConfig {
        CustomReportConfig(
            id: "r", name: "Test", mode: mode, groupBy: groupBy, balanceType: balance,
            interval: interval, graphType: graph, dateRange: dateRange,
            dateStatic: staticRange != nil,
            startDate: staticRange?.start, endDate: staticRange?.end,
            includeCurrent: true, showEmpty: showEmpty,
            showOffBudget: showOffBudget, showHidden: false, showUncategorized: showUncategorized,
            sortBy: sortBy, showTrendLines: showTrendLines, trimIntervals: trimIntervals,
            conditions: conditions, conditionsOp: "and")
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
        let barLine = CustomReportEngine.compute(
            config: config(mode: "total", groupBy: "Category", balance: "Payment",
                           interval: "Monthly", graph: "BarLineGraph"),
            transactions: [], reportContext: reportContext, filterContext: .empty, today: today)
        guard case .unsupported(let reason) = barLine.kind else {
            Issue.record("expected unsupported, got \(barLine.kind)"); return
        }
        #expect(reason.contains("BarLineGraph"))

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

    // MARK: - groupBy Payee / Account

    @Test func payeeBarsUseStoreOrderAndSkipPayeeless() {
        // Upstream matches `payee === item.id` with no synthetic rows, so a
        // tx without a payee lands nowhere; transfer payees show the linked
        // account's name (v_payees).
        let txs = [
            tx("1", date: 20260601, amount: -10_000, category: "c-food", payee: "p-store"),
            tx("2", date: 20260615, amount: -4_000,  category: "c-rent", payee: "p-xfer"),
            tx("3", date: 20260701, amount: -5_000,  category: "c-fun"),   // no payee
        ]
        let data = CustomReportEngine.compute(
            config: config(mode: "total", groupBy: "Payee", balance: "Payment",
                           interval: "Monthly", graph: "BarGraph", sortBy: "budget"),
            transactions: txs, reportContext: reportContext, filterContext: .empty, today: today)
        guard case .bars(let bars, _) = data.kind else {
            Issue.record("expected bars, got \(data.kind)"); return
        }
        #expect(bars.map(\.label) == ["Store", "Savings"])
        #expect(bars.map(\.valueUnits) == [100.0, 40.0])
    }

    @Test func accountBarsFollowShowOffBudget() {
        var ctx = reportContext
        ctx.offBudgetAccountIds = ["a-off"]
        let txs = [
            tx("1", date: 20260601, amount: -10_000, category: "c-food"),
            tx("2", date: 20260615, amount: -4_000,  category: nil, account: "a-off"),
        ]
        func run(showOffBudget: Bool) -> [CustomReportData.Bar] {
            let data = CustomReportEngine.compute(
                config: config(mode: "total", groupBy: "Account", balance: "Payment",
                               interval: "Monthly", graph: "BarGraph", sortBy: "budget",
                               showOffBudget: showOffBudget),
                transactions: txs, reportContext: ctx, filterContext: .empty, today: today)
            guard case .bars(let bars, _) = data.kind else { return [] }
            return bars
        }
        #expect(run(showOffBudget: true).map(\.label) == ["Checking", "Brokerage"])
        #expect(run(showOffBudget: true).map(\.valueUnits) == [100.0, 40.0])
        #expect(run(showOffBudget: false).map(\.label) == ["Checking"])
    }

    // MARK: - Net Payment / Net Deposit

    @Test func netPaymentUsesRowTotalNotBucketSum() {
        // Food: -100 in Jun, +150 in Jul → whole-range net +50. Upstream's
        // recalculate() derives netDebts from that net, so the row is empty
        // under Net Payment and 50 under Net Deposit; per-interval values
        // still split by bucket.
        let txs = [
            tx("1", date: 20260601, amount: -10_000, category: "c-food"),
            tx("2", date: 20260701, amount: 15_000,  category: "c-food"),
        ]
        func run(balance: String, graph: String) -> CustomReportData.Kind {
            CustomReportEngine.compute(
                config: config(mode: graph == "BarGraph" ? "total" : "time", groupBy: "Category",
                               balance: balance, interval: "Monthly", graph: graph),
                transactions: txs, reportContext: reportContext, filterContext: .empty, today: today).kind
        }
        guard case .bars(let payment, _) = run(balance: "Net Payment", graph: "BarGraph"),
              case .bars(let deposit, _) = run(balance: "Net Deposit", graph: "BarGraph"),
              case .stacked(let perMonth) = run(balance: "Net Deposit", graph: "StackedBarGraph") else {
            Issue.record("expected bars and stacked"); return
        }
        #expect(payment.isEmpty)
        #expect(deposit.map(\.label) == ["Food"])
        #expect(deposit.map(\.valueUnits) == [50.0])
        #expect(perMonth.values == [[0.0, 150.0]])
    }

    @Test func netPaymentPerIntervalBars() {
        // Jun net -300 → 300; Jul net -50 (income row dropped) → 50.
        let data = CustomReportEngine.compute(
            config: config(mode: "total", groupBy: "Interval", balance: "Net Payment",
                           interval: "Monthly", graph: "BarGraph"),
            transactions: sampleTxs, reportContext: reportContext,
            filterContext: .empty, today: today)
        guard case .bars(let bars, let signed) = data.kind else {
            Issue.record("expected bars, got \(data.kind)"); return
        }
        #expect(signed == false)
        #expect(bars.map(\.valueUnits) == [300.0, 50.0])
    }

    // MARK: - Budgeted

    @Test func budgetedReadsBudgetCellsAndOnlyCategoryConditions() {
        // Upstream budgetDataQuery: months in range, non-income categories,
        // and only category / category_group conditions apply.
        var ctx = reportContext
        ctx.budgetEntries = [
            BudgetAnalysisBudgetEntry(month: 202605, categoryId: "c-food", amountCents: 99_900),   // before range
            BudgetAnalysisBudgetEntry(month: 202606, categoryId: "c-food", amountCents: 50_000),
            BudgetAnalysisBudgetEntry(month: 202606, categoryId: "c-rent", amountCents: 120_000),
            BudgetAnalysisBudgetEntry(month: 202607, categoryId: "c-food", amountCents: 50_000),
            BudgetAnalysisBudgetEntry(month: 202606, categoryId: "c-salary", amountCents: 300_000), // income
        ]
        func run(conditions: [WidgetRuleCondition]?) -> [CustomReportData.Bar] {
            let data = CustomReportEngine.compute(
                config: config(mode: "total", groupBy: "Category", balance: "Budgeted",
                               interval: "Monthly", graph: "BarGraph", sortBy: "budget",
                               conditions: conditions),
                transactions: sampleTxs, reportContext: ctx, filterContext: .empty, today: today)
            guard case .bars(let bars, _) = data.kind else { return [] }
            return bars
        }
        let accountOnly = run(conditions: [.makeMock(op: "is", field: "account", stringValue: "a-off")])
        #expect(accountOnly.map(\.label) == ["Food", "Rent"])
        #expect(accountOnly.map(\.valueUnits) == [1000.0, 1200.0])
        let foodOnly = run(conditions: [.makeMock(op: "is", field: "category", stringValue: "c-food")])
        #expect(foodOnly.map(\.label) == ["Food"])
        #expect(foodOnly.map(\.valueUnits) == [1000.0])
    }

    @Test func budgetedSurvivesInvertedRange() {
        // "Last year" on a budget whose history starts this year resolves to
        // a start after its end (ReportDateRange clamps the start to the
        // earliest transaction). That is an empty chart, not a trap.
        var ctx = reportContext
        ctx.budgetEntries = [
            BudgetAnalysisBudgetEntry(month: 202606, categoryId: "c-food", amountCents: 50_000),
        ]
        let data = CustomReportEngine.compute(
            config: config(mode: "total", groupBy: "Category", balance: "Budgeted",
                           interval: "Monthly", graph: "BarGraph", dateRange: "Last year"),
            transactions: sampleTxs, reportContext: ctx, filterContext: .empty, today: today)
        guard case .bars(let bars, _) = data.kind else {
            Issue.record("expected bars, got \(data.kind)"); return
        }
        #expect(bars.isEmpty)
    }

    // MARK: - Donut

    @Test func donutOverIntervals() {
        // Upstream allows Interval grouping on a total-mode donut: one wedge
        // per interval, empty intervals dropped.
        let data = CustomReportEngine.compute(
            config: config(mode: "total", groupBy: "Interval", balance: "Payment",
                           interval: "Monthly", graph: "DonutGraph"),
            transactions: sampleTxs, reportContext: reportContext,
            filterContext: .empty, today: today)
        guard case .donut(let slices, let groups) = data.kind else {
            Issue.record("expected donut, got \(data.kind)"); return
        }
        #expect(groups.isEmpty)
        #expect(slices.map(\.label) == ["Jun '26", "Jul '26"])
        #expect(slices.map(\.valueUnits) == [300.0, 50.0])
    }

    @Test func donutDropsZeroSlices() {
        let data = CustomReportEngine.compute(
            config: config(mode: "total", groupBy: "Category", balance: "Payment",
                           interval: "Monthly", graph: "DonutGraph", showEmpty: true),
            transactions: sampleTxs, reportContext: reportContext,
            filterContext: .empty, today: today)
        guard case .donut(let slices, let groups) = data.kind else {
            Issue.record("expected donut, got \(data.kind)"); return
        }
        #expect(groups.isEmpty)
        #expect(slices.map(\.label) == ["Rent", "Food", "Fun"])   // desc; empties gone
        #expect(slices.map(\.valueUnits) == [200.0, 100.0, 50.0])
        #expect(slices.allSatisfy { $0.group == nil })
    }

    @Test func donutTwoRingsAlignSlicesToGroups() {
        let data = CustomReportEngine.compute(
            config: config(mode: "total", groupBy: "CategoryGroup", balance: "Payment",
                           interval: "Monthly", graph: "DonutGraph"),
            transactions: sampleTxs, reportContext: reportContext,
            filterContext: .empty, today: today)
        guard case .donut(let slices, let groups) = data.kind else {
            Issue.record("expected donut, got \(data.kind)"); return
        }
        #expect(groups.map(\.label) == ["Living", "Play"])       // desc: 300 vs 50
        #expect(groups.map(\.valueUnits) == [300.0, 50.0])
        #expect(slices.map(\.label) == ["Rent", "Food", "Fun"])  // grouped, desc within group
        #expect(slices.map(\.group) == [0, 0, 1])
        for (gi, group) in groups.enumerated() {
            let members = slices.filter { $0.group == gi }.map(\.valueUnits).reduce(0, +)
            #expect(members == group.valueUnits)
        }
    }

    @Test func donutTwoRingsLocalizeSyntheticGroup() {
        let data = CustomReportEngine.compute(
            config: config(mode: "total", groupBy: "CategoryGroup", balance: "Payment",
                           interval: "Monthly", graph: "DonutGraph", showUncategorized: true),
            transactions: [tx("uncategorized", date: 20260701, amount: -5_000, category: nil)],
            reportContext: reportContext, filterContext: .empty, today: today,
            locale: Locale(identifier: "fr_FR"), bundle: Bundle.main)
        guard case .donut(_, let groups) = data.kind else {
            Issue.record("expected donut, got \(data.kind)"); return
        }
        #expect(groups.map(\.label) == ["Sans catégorie et hors budget"])
    }

    // MARK: - Line / Area

    @Test func lineSeriesMatchStackedAndCarryTrends() {
        func run(showTrendLines: Bool) -> CustomReportData.Kind {
            CustomReportEngine.compute(
                config: config(mode: "time", groupBy: "Category", balance: "Payment",
                               interval: "Monthly", graph: "LineGraph", showTrendLines: showTrendLines),
                transactions: sampleTxs, reportContext: reportContext,
                filterContext: .empty, today: today).kind
        }
        guard case .lines(let plain, let noTrends) = run(showTrendLines: false),
              case .lines(let withTrends, let trends) = run(showTrendLines: true) else {
            Issue.record("expected lines"); return
        }
        #expect(noTrends.isEmpty)
        #expect(plain == withTrends)
        #expect(plain.seriesNames == ["Rent", "Food", "Fun"])
        #expect(plain.values == [[200.0, 0.0], [100.0, 0.0], [0.0, 50.0]])
        // One trend per series; Rent [200, 0] fits a straight line exactly.
        #expect(trends.count == 3)
        #expect(trends[0] == .init(startUnits: 200.0, endUnits: 0.0))
    }

    @Test func trendLineIsLeastSquares() throws {
        #expect(CustomReportEngine.trend([1, 2, 3]) == .init(startUnits: 1.0, endUnits: 3.0))
        #expect(CustomReportEngine.trend([2, 2]) == .init(startUnits: 2.0, endUnits: 2.0))
        // y = 1, 3, 2 → slope 0.5, intercept 1.5
        let fitted = try #require(CustomReportEngine.trend([1, 3, 2]))
        #expect(abs(fitted.startUnits - 1.5) < 1e-9)
        #expect(abs(fitted.endUnits - 2.5) < 1e-9)
        #expect(CustomReportEngine.trend([5]) == nil)
    }

    @Test func areaEmitsOnePointPerInterval() {
        let data = CustomReportEngine.compute(
            config: config(mode: "total", groupBy: "Interval", balance: "Payment",
                           interval: "Monthly", graph: "AreaGraph"),
            transactions: sampleTxs, reportContext: reportContext,
            filterContext: .empty, today: today)
        guard case .area(let points) = data.kind else {
            Issue.record("expected area, got \(data.kind)"); return
        }
        #expect(points.map(\.label) == ["Jun '26", "Jul '26"])
        #expect(points.map(\.valueUnits) == [300.0, 50.0])
    }

    // MARK: - Trim intervals / sort

    @Test func trimIntervalsDropsEmptyEdges() {
        // Static Mar–Aug range with activity only in May and June.
        let txs = [
            tx("1", date: 20260510, amount: -10_000, category: "c-food"),
            tx("2", date: 20260620, amount: -5_000,  category: "c-fun"),
        ]
        func run(trim: Bool, groupBy: String) -> [String] {
            let data = CustomReportEngine.compute(
                config: config(mode: "time", groupBy: groupBy, balance: "Payment",
                               interval: "Monthly", graph: groupBy == "Interval" ? "BarGraph" : "StackedBarGraph",
                               trimIntervals: trim, staticRange: ("2026-03-01", "2026-08-31")),
                transactions: txs, reportContext: reportContext, filterContext: .empty, today: today)
            switch data.kind {
            case .stacked(let s): return s.intervalLabels
            case .bars(let bars, _): return bars.map(\.label)
            default: return []
            }
        }
        #expect(run(trim: false, groupBy: "Category").count == 6)
        #expect(run(trim: true, groupBy: "Category") == ["May '26", "Jun '26"])
        #expect(run(trim: true, groupBy: "Interval") == ["May '26", "Jun '26"])
    }

    @Test func descSortIsSignedForNet() {
        // Upstream sortData compares the signed metric, so under Net the
        // biggest inflow comes first and the biggest outflow last.
        let txs = [
            tx("1", date: 20260601, amount: -10_000, category: "c-food"),
            tx("2", date: 20260601, amount: 25_000,  category: "c-rent"),
            tx("3", date: 20260601, amount: -5_000,  category: "c-fun"),
        ]
        let data = CustomReportEngine.compute(
            config: config(mode: "total", groupBy: "Category", balance: "Net",
                           interval: "Monthly", graph: "BarGraph"),
            transactions: txs, reportContext: reportContext, filterContext: .empty, today: today)
        guard case .bars(let bars, _) = data.kind else {
            Issue.record("expected bars, got \(data.kind)"); return
        }
        #expect(bars.map(\.label) == ["Rent", "Fun", "Food"])
        #expect(bars.map(\.valueUnits) == [250.0, -50.0, -100.0])
    }

    @Test func nameSortUsesExplicitLocaleAndStableTies() {
        var context = reportContext
        context.categories = [
            Category(id: "c-zebra", name: "Zebra", groupId: "g-living", isIncome: false, hidden: false, sortOrder: 0),
            Category(id: "c-angstrom", name: "Ångström", groupId: "g-living", isIncome: false, hidden: false, sortOrder: 1),
            Category(id: "c-cafe", name: "Cafe", groupId: "g-living", isIncome: false, hidden: false, sortOrder: 2),
            Category(id: "c-cafe-accent", name: "Café", groupId: "g-living", isIncome: false, hidden: false, sortOrder: 3),
        ]
        let transactions = [
            tx("zebra", date: 20260701, amount: -100, category: "c-zebra"),
            tx("angstrom", date: 20260701, amount: -100, category: "c-angstrom"),
            tx("cafe", date: 20260701, amount: -100, category: "c-cafe"),
            tx("cafe-accent", date: 20260701, amount: -100, category: "c-cafe-accent"),
        ]
        func names(_ locale: Locale) -> [String] {
            let data = CustomReportEngine.compute(
                config: config(mode: "total", groupBy: "Category", balance: "Payment",
                               interval: "Monthly", graph: "BarGraph", sortBy: "name"),
                transactions: transactions, reportContext: context,
                filterContext: .empty, today: today, locale: locale)
            guard case .bars(let bars, _) = data.kind else { return [] }
            return bars.map(\.label)
        }

        #expect(names(Locale(identifier: "en_US")) == ["Ångström", "Cafe", "Café", "Zebra"])
        #expect(names(Locale(identifier: "sv_SE")) == ["Cafe", "Café", "Zebra", "Ångström"])
    }

    @Test func chartAmountFormattingUsesSelectedNumberFormat() {
        let arguments: [(ActualNumberFormat, String)] = [
            (.commaDot, "$1,000.33"),
            (.dotComma, "$1.000,33"),
            (.spaceComma, "$1\u{202F}000,33"),
        ]
        for (format, expected) in arguments {
            #expect(CustomReportChartAccessibility.amount(
                units: 1000.33, numberFormat: format, currencyCode: "USD",
                narrowSymbol: true, locale: Locale(identifier: "en_US")) == expected)
        }
    }

    @Test func reportCurrencyAxisUsesSelectedNumberFormat() {
        let locale = Locale(identifier: "en_US")
        #expect(ReportCurrencyAxisFormatting.label(
            units: 1000.33, numberFormat: .commaDot, currencyCode: "USD",
            narrowSymbol: true, locale: locale) == "$1,000.33")
        #expect(ReportCurrencyAxisFormatting.label(
            units: 1000.33, numberFormat: .dotComma, currencyCode: "USD",
            narrowSymbol: true, locale: locale) == "$1.000,33")
    }

    @Test func reportCurrencyAxisPreservesHiddenBalanceSemantics() {
        #expect(ReportCurrencyAxisFormatting.hidesAxis(for: true))
        #expect(!ReportCurrencyAxisFormatting.hidesAxis(for: false))
    }

    @Test func chartAccessibilityRowsExposeSeriesLabelsAndValues() {
        let format = ActualNumberFormat.commaDot
        let locale = Locale(identifier: "en_US")
        let bars = CustomReportChartAccessibility.rows(
            for: .bars([.init(label: "Food", valueUnits: 12.34)], signed: false),
            numberFormat: format, currencyCode: "USD", narrowSymbol: true, locale: locale)
        #expect(bars == [.init(series: nil, label: "Food", value: "$12.34")])

        let stacked = CustomReportChartAccessibility.rows(
            for: .stacked(.init(intervalLabels: ["Jun '26"], seriesNames: ["Living"], values: [[12.34]])),
            numberFormat: format, currencyCode: "USD", narrowSymbol: true, locale: locale)
        #expect(stacked == [.init(series: "Living", label: "Jun '26", value: "$12.34")])

        let lines = CustomReportChartAccessibility.rows(
            for: .lines(.init(intervalLabels: ["Jun '26"], seriesNames: ["Living"], values: [[12.34]]), trends: []),
            numberFormat: format, currencyCode: "USD", narrowSymbol: true, locale: locale)
        #expect(lines == stacked)

        let area = CustomReportChartAccessibility.rows(
            for: .area([.init(label: "Jun '26", valueUnits: 12.34)]),
            numberFormat: format, currencyCode: "USD", narrowSymbol: true, locale: locale)
        #expect(area == [.init(series: nil, label: "Jun '26", value: "$12.34")])

        let oneRing = CustomReportChartAccessibility.rows(
            for: .donut(slices: [.init(label: "Food", valueUnits: 12.34, group: nil)], groups: []),
            numberFormat: format, currencyCode: "USD", narrowSymbol: true, locale: locale)
        #expect(oneRing == [.init(series: nil, label: "Food", value: "$12.34")])

        let twoRing = CustomReportChartAccessibility.rows(
            for: .donut(
                slices: [.init(label: "Food", valueUnits: 12.34, group: 0)],
                groups: [.init(label: "Living", valueUnits: 12.34)]),
            numberFormat: format, currencyCode: "USD", narrowSymbol: true, locale: locale)
        #expect(twoRing == [
            .init(series: nil, label: "Living", value: "$12.34"),
            .init(series: "Living", label: "Food", value: "$12.34"),
        ])
    }
}

extension CustomReportEngineTests {
    @Test func gregorianYearForThaiRegion() {
        let data = CustomReportEngine.compute(
            config: config(mode: "total", groupBy: "Interval", balance: "Net",
                           interval: "Yearly", graph: "BarGraph"),
            transactions: sampleTxs, reportContext: reportContext,
            filterContext: .empty, today: today, locale: Locale(identifier: "th_TH"))
        guard case .bars(let bars, _) = data.kind else { Issue.record("Expected bars"); return }
        #expect(bars.map(\.label) == ["2026"])
    }
}
