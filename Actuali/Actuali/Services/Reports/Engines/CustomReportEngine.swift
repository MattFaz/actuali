import Foundation

struct CustomReportData: Equatable {
    var name: String
    var rangeLabel: String   // "All time", "Year to date", or "" for static

    struct Bar: Equatable { var label: String; var valueUnits: Double }
    struct Stacked: Equatable {
        var intervalLabels: [String]
        var seriesNames: [String]     // legend, ordered
        var values: [[Double]]        // [series][interval], currency units
    }
    struct TableRow: Equatable { var name: String; var totalUnits: Double }
    /// One donut wedge. `group` indexes `Kind.donut`'s `groups` ring for the
    /// two-ring Category+Group layout; nil on a single-ring donut.
    struct Slice: Equatable { var label: String; var valueUnits: Double; var group: Int? }
    /// Least-squares trend through one line series, as its values at the
    /// first and last interval.
    struct Trend: Equatable { var startUnits: Double; var endUnits: Double }

    enum Kind: Equatable {
        case bars([Bar], signed: Bool)   // signed → color bars by sign (Net)
        case stacked(Stacked)
        case lines(Stacked, trends: [Trend])   // trends empty unless showTrendLines
        case area([Bar])                       // one point per interval
        case donut(slices: [Slice], groups: [Bar])   // groups empty → single ring
        case table([TableRow])
        case unsupported(String)
    }
    var kind: Kind
}

/// Port of the webapp's custom-spreadsheet.ts for the option matrix the web
/// UI can save. Everything computes from the shared reports transaction
/// array (or, for the Budgeted balance type, from budget cells); configs
/// outside the matrix return `.unsupported` naming the offending option so
/// the card can explain itself.
enum CustomReportEngine {

    /// Row keys for the synthetic rows upstream appends after the real
    /// categories/groups (ReportOptions.ts: uncategorizedCategory,
    /// offBudgetCategory, transferCategory, uncategorizedGroup).
    private enum Synthetic {
        static let uncategorized = "uncategorized"
        static let offBudget = "off_budget"
        static let transfer = "transfer"
    }

    struct ReportContext {
        var categories: [Category]       // in budget sort order
        var groups: [CategoryGroup]      // in budget sort order
        var offBudgetAccountIds: Set<String>
        var firstDayOfWeekIdx: Int
        var payees: [Payee] = []                              // groupBy Payee, store order
        var accounts: [Account] = []                          // groupBy Account, store order
        var budgetEntries: [BudgetAnalysisBudgetEntry] = []   // balanceType Budgeted
    }

    /// Assets/debts sums for one row or bucket (upstream QueryDataEntity split).
    private struct Cell {
        var assets = 0
        var debts = 0

        mutating func add(_ amount: Int) {
            if amount > 0 { assets += amount } else { debts += amount }
        }

        static func + (lhs: Cell, rhs: Cell) -> Cell {
            Cell(assets: lhs.assets + rhs.assets, debts: lhs.debts + rhs.debts)
        }
    }

    /// One named row (category, group, payee, account) after bucketing.
    private struct Row {
        let key: String
        let name: String
        let cell: Cell            // whole-range aggregate
        var perBucket: [Double]   // metric per interval, currency units
        let total: Double         // metric over the aggregate, not Σ perBucket
    }

    static func compute(
        config: CustomReportConfig?,
        transactions: [Transaction],
        reportContext: ReportContext,
        filterContext: ConditionsFilter.Context,
        today: Date,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> CustomReportData {
        guard let config else {
            return CustomReportData(
                name: ReportStrings.text("Custom Report", locale: locale, bundle: bundle),
                rangeLabel: "",
                kind: .unsupported(ReportStrings.text("Report not found — try syncing", locale: locale, bundle: bundle))
            )
        }
        var data = CustomReportData(name: config.name,
                                    rangeLabel: config.dateStatic ? "" : localizedRangeLabel(
                                        config.dateRange ?? "All time", locale: locale, bundle: bundle),
                                    kind: .unsupported(""))

        // Supported-matrix guard (upstream ReportOptions.ts): name the first
        // offending option.
        for (value, supported, label) in [
            (config.mode, ["total", "time"], "mode"),
            (config.groupBy, ["Category", "Group", "CategoryGroup", "Payee", "Account", "Interval"], "group by"),
            (config.balanceType, ["Payment", "Deposit", "Net", "Net Payment", "Net Deposit", "Budgeted"], "balance type"),
            (config.interval, ["Daily", "Weekly", "Monthly", "Yearly"], "interval"),
            (config.graphType, ["BarGraph", "StackedBarGraph", "LineGraph", "AreaGraph", "DonutGraph", "TableGraph"], "graph"),
        ] where !supported.contains(value) {
            data.kind = .unsupported(ReportStrings.format(
                "%@ %@ isn't supported yet", value,
                ReportStrings.text(label, locale: locale, bundle: bundle),
                locale: locale, bundle: bundle
            ))
            return data
        }

        // Date range from actual history (also for Budgeted, as upstream's
        // card does).
        let live = transactions.filter { !$0.tombstone }
        let earliest = live.map(\.date).min().map(dateFrom)
        let latest = live.map(\.date).max().map(dateFrom)
        let (start, end) = ReportDateRange.resolve(
            dateRange: config.dateRange, dateStatic: config.dateStatic,
            startDate: config.startDate, endDate: config.endDate,
            includeCurrent: config.includeCurrent,
            earliest: earliest, latest: latest, today: today,
            firstDayOfWeekIdx: reportContext.firstDayOfWeekIdx)
        let startYMD = ymdInt(from: start), endYMD = ymdInt(from: end)
        let categoriesById = Dictionary(uniqueKeysWithValues: reportContext.categories.map { ($0.id, $0) })
        let groupsById = Dictionary(uniqueKeysWithValues: reportContext.groups.map { ($0.id, $0) })

        // Dataset: transactions in range, or budget cells for Budgeted
        // (upstream fetchSpreadsheetQueryData). Budget cells only honour
        // category conditions (budgetDataQuery.filterCategoriesByConditions).
        let budgeted = config.balanceType == "Budgeted"
        let source = budgeted
            ? budgetRows(reportContext, startYMD: startYMD, endYMD: endYMD)
            : live.filter { $0.date >= startYMD && $0.date <= endYMD }
        let conditions = budgeted
            ? config.conditions?.filter { ["category", "category_group"].contains($0.field) }
            : config.conditions

        // Filter (upstream: conditions, then filterHiddenItems) — single pass.
        // Category resolves through the lookup, mirroring upstream's query
        // join: a dangling categoryId behaves exactly like no category.
        let pool = source.filter { tx in
            guard ConditionsFilter.matches(transaction: tx, conditions: conditions,
                                           op: config.conditionsOp, context: filterContext)
            else { return false }
            let category = tx.categoryId.flatMap { categoriesById[$0] }
            if !config.showHidden, let category,
               category.hidden || (groupsById[category.groupId]?.hidden ?? false) {
                return false
            }
            let offBudget = reportContext.offBudgetAccountIds.contains(tx.accountId)
            if !config.showOffBudget && offBudget { return false }
            if !config.showUncategorized && category == nil && !offBudget { return false }
            return true
        }

        // Interval buckets, chronological.
        let buckets = intervalBuckets(from: start, to: end,
                                      interval: config.interval,
                                      firstDayOfWeekIdx: reportContext.firstDayOfWeekIdx,
                                      locale: locale)
        let bucketIndex = Dictionary(uniqueKeysWithValues:
            buckets.enumerated().map { ($0.element.key, $0.offset) })
        var labels = buckets.map(\.label)

        // Accumulate assets/debts per (row, bucket). Row key "" = whole
        // dataset (groupBy Interval).
        var cells: [String: [Int: Cell]] = [:]   // rowKey -> bucketIdx -> sums
        for tx in pool {
            let key = bucketKey(forYMD: tx.date, interval: config.interval,
                                firstDayOfWeekIdx: reportContext.firstDayOfWeekIdx)
            guard let idx = bucketIndex[key] else { continue }
            // Upstream filterHiddenItems: only categorized on-budget txs land
            // on regular rows; everything else goes to the synthetic rows —
            // off-budget txs (even categorized ones) to "Off budget", then
            // uncategorized transfers to "Transfers", the rest to
            // "Uncategorized". Group mode folds all three into one group.
            // Payee/Account have no synthetic rows: a tx with no payee
            // matches nothing (upstream `payee === item.id`).
            let category = tx.categoryId.flatMap { categoriesById[$0] }
            let offBudget = reportContext.offBudgetAccountIds.contains(tx.accountId)
            let rowKey: String
            switch config.groupBy {
            case "Category":
                if let category, !offBudget { rowKey = category.id }
                else if offBudget { rowKey = Synthetic.offBudget }
                else if tx.transferAcct != nil { rowKey = Synthetic.transfer }
                else { rowKey = Synthetic.uncategorized }
            case "CategoryGroup":
                if let category, !offBudget { rowKey = category.id }
                else if offBudget { rowKey = Synthetic.offBudget }
                else if tx.transferAcct != nil { rowKey = Synthetic.transfer }
                else { rowKey = Synthetic.uncategorized }
            case "Group":
                if let category, !offBudget { rowKey = category.groupId }
                else { rowKey = Synthetic.uncategorized }
            case "Payee":
                guard let payee = tx.payeeId else { continue }
                rowKey = payee
            case "Account":
                rowKey = tx.accountId
            default: rowKey = ""   // Interval
            }
            cells[rowKey, default: [:]][idx, default: Cell()].add(tx.amount)
        }

        let value = { (cell: Cell) in metric(cell, balanceType: config.balanceType) }
        func bucketCells(_ rowKey: String) -> [Cell] {
            (0..<buckets.count).map { cells[rowKey]?[$0] ?? Cell() }
        }
        let signed = ["Net", "Budgeted"].contains(config.balanceType)

        // groupBy Interval → one row per bucket (web renders intervalData here).
        if config.groupBy == "Interval" {
            var values = bucketCells("").map(value)
            if config.trimIntervals {
                let range = trimmedRange([values])
                labels = Array(labels[range])
                values = Array(values[range])
            }
            switch config.graphType {
            case "TableGraph":
                data.kind = .table(zip(labels, values).map { .init(name: $0, totalUnits: $1) })
            case "AreaGraph":
                data.kind = .area(zip(labels, values).map { .init(label: $0, valueUnits: $1) })
            case "DonutGraph":
                // Upstream allows Interval on a total-mode donut: one wedge
                // per interval, and a wedge can't have a non-positive angle.
                data.kind = .donut(slices: zip(labels, values).filter { $0.1 > 0 }
                                       .map { .init(label: $0, valueUnits: $1, group: nil) },
                                   groups: [])
            default:
                data.kind = .bars(zip(labels, values).map { .init(label: $0, valueUnits: $1) },
                                  signed: signed)
            }
            return data
        }

        // Named rows in store order. Upstream (ReportOptions.categoryLists)
        // always appends the synthetic rows; when their txs are filtered out
        // they total zero and fall to the showEmpty filter like any other row.
        let orderedRows: [(key: String, name: String)]
        switch config.groupBy {
        case "Group":
            orderedRows = reportContext.groups.map { ($0.id, $0.name) }
                + [(Synthetic.uncategorized, ReportStrings.text(
                    "Uncategorized & Off budget", locale: locale, bundle: bundle))]
        case "Payee":
            // Transfer payees carry no name of their own; upstream's v_payees
            // shows the linked account.
            let accountNames = Dictionary(reportContext.accounts.map { ($0.id, $0.name) },
                                          uniquingKeysWith: { first, _ in first })
            orderedRows = reportContext.payees.map { payee in
                (payee.id, payee.transferAccountId.flatMap { accountNames[$0] } ?? payee.name)
            }
        case "Account":
            orderedRows = reportContext.accounts.map { ($0.id, $0.name) }
        case "Category", "CategoryGroup":
            orderedRows = reportContext.categories.map { ($0.id, $0.name) } + [
                (Synthetic.uncategorized, ReportStrings.text(
                    "Uncategorized", locale: locale, bundle: bundle)),
                (Synthetic.offBudget, ReportStrings.text(
                    "Off budget", locale: locale, bundle: bundle)),
                (Synthetic.transfer, ReportStrings.text(
                    "Transfers", locale: locale, bundle: bundle)),
            ]
        default:
            orderedRows = reportContext.groups.map { ($0.id, $0.name) }
                + [(Synthetic.uncategorized, ReportStrings.text(
                    "Uncategorized & Off budget", locale: locale, bundle: bundle))]
        }

        var rows: [Row] = orderedRows.map { row in
            let perBucket = bucketCells(row.key)
            let cell = perBucket.reduce(Cell(), +)
            return Row(key: row.key, name: row.name, cell: cell,
                       perBucket: perBucket.map(value), total: value(cell))
        }
        // Upstream filterEmptyRows: Net/Budgeted keep any row with activity;
        // the rest keep rows whose metric is non-zero. For Net Payment /
        // Net Deposit that is the row's whole-range net, so a row that is
        // negative in one month but positive overall hides under Net Payment.
        if !config.showEmpty {
            rows = rows.filter { signed ? ($0.cell.assets != 0 || $0.cell.debts != 0) : $0.total != 0 }
        }
        // Upstream trimIntervals.ts: span from the first to the last interval
        // where any surviving row, or the overall total, is non-zero.
        if config.trimIntervals {
            let overall = (0..<buckets.count).map { i in
                value(cells.values.reduce(Cell()) { $0 + ($1[i] ?? Cell()) })
            }
            let range = trimmedRange(rows.map(\.perBucket) + [overall])
            labels = Array(labels[range])
            for i in rows.indices { rows[i].perBucket = Array(rows[i].perBucket[range]) }
        }
        rows = sorted(rows, by: config.sortBy, total: \.total, name: \.name, locale: locale)

        switch config.graphType {
        case "TableGraph":
            data.kind = .table(rows.map { .init(name: $0.name, totalUnits: $0.total) })
        case "StackedBarGraph":
            data.kind = .stacked(series(rows, labels: labels))
        case "LineGraph":
            let s = series(rows, labels: labels)
            data.kind = .lines(s, trends: config.showTrendLines ? s.values.compactMap(trend) : [])
        case "DonutGraph" where config.groupBy == "CategoryGroup":
            data.kind = twoRingDonut(rows, context: reportContext,
                                     categoriesById: categoriesById, sortBy: config.sortBy,
                                     locale: locale, bundle: bundle)
        case "DonutGraph":
            // A wedge can't have a negative angle; upstream disables Net here,
            // so every allowed metric is already non-negative.
            data.kind = .donut(slices: rows.filter { $0.total > 0 }
                                   .map { .init(label: $0.name, valueUnits: $0.total, group: nil) },
                               groups: [])
        default:
            data.kind = .bars(rows.map { .init(label: $0.name, valueUnits: $0.total) }, signed: signed)
        }
        return data
    }

    // MARK: - Metric

    /// Upstream balanceTypeMap: Payment = |debts|, Deposit = assets,
    /// Net Payment = |net| when negative, Net Deposit = net when positive,
    /// Net and Budgeted = signed net (totalBudgeted mirrors totalTotals; only
    /// the dataset differs).
    private static func metric(_ cell: Cell, balanceType: String) -> Double {
        let net = cell.assets + cell.debts
        switch balanceType {
        case "Payment":     return Double(-cell.debts) / 100
        case "Deposit":     return Double(cell.assets) / 100
        case "Net Payment": return net < 0 ? Double(-net) / 100 : 0
        case "Net Deposit": return net > 0 ? Double(net) / 100 : 0
        default:            return Double(net) / 100
        }
    }

    /// Upstream sortData.ts sorts by the signed metric (its debts reversal is
    /// already baked in because Payment is stored positive here).
    private static func sorted<T>(
        _ items: [T], by sortBy: String,
        total: KeyPath<T, Double>, name: KeyPath<T, String>, locale: Locale
    ) -> [T] {
        switch sortBy {
        case "asc":  return items.sorted { $0[keyPath: total] < $1[keyPath: total] }
        case "name":
            return items.enumerated().sorted { lhs, rhs in
                let comparison = lhs.element[keyPath: name].compare(
                    rhs.element[keyPath: name],
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: nil,
                    locale: locale)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                let exactComparison = lhs.element[keyPath: name].compare(
                    rhs.element[keyPath: name], options: [.caseInsensitive],
                    range: nil, locale: locale)
                if exactComparison != .orderedSame {
                    return exactComparison == .orderedAscending
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
        case "budget": return items                 // keep store order
        default:     return items.sorted { $0[keyPath: total] > $1[keyPath: total] }  // desc
        }
    }

    private static func series(_ rows: [Row], labels: [String]) -> CustomReportData.Stacked {
        .init(intervalLabels: labels, seriesNames: rows.map(\.name), values: rows.map(\.perBucket))
    }

    /// First…last interval where any series is non-zero; empty when none is.
    private static func trimmedRange(_ series: [[Double]]) -> Range<Int> {
        let count = series.first?.count ?? 0
        let nonEmpty = (0..<count).map { i in series.contains { $0[i] != 0 } }
        guard let first = nonEmpty.firstIndex(of: true),
              let last = nonEmpty.lastIndex(of: true) else { return 0..<0 }
        return first..<(last + 1)
    }

    /// Least-squares line through the series (upstream computeTrendLines.ts)
    /// over x = 0…n-1. Needs two points.
    static func trend(_ ys: [Double]) -> CustomReportData.Trend? {
        guard ys.count >= 2 else { return nil }
        let n = Double(ys.count)
        let sumX = n * (n - 1) / 2
        let sumX2 = (n - 1) * n * (2 * n - 1) / 6
        let sumY = ys.reduce(0, +)
        let sumXY = ys.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element }
        let slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX)
        let intercept = (sumY - slope * sumX) / n
        return .init(startUnits: intercept, endUnits: intercept + slope * (n - 1))
    }

    // MARK: - Budgeted dataset

    /// Upstream budgetDataQuery.fetchBudgetData: one row per month in range
    /// per non-income category with a non-zero budget, keyed to the month.
    /// Emitted as synthetic transactions so the same bucketing and row
    /// filters apply.
    private static func budgetRows(_ context: ReportContext, startYMD: Int, endYMD: Int) -> [Transaction] {
        let income = Set(context.categories.filter(\.isIncome).map(\.id))
        return context.budgetEntries.compactMap { entry in
            guard entry.amountCents != 0, !income.contains(entry.categoryId),
                  entry.month >= startYMD / 100, entry.month <= endYMD / 100 else { return nil }
            // ponytail: cells sit on the 1st, so Daily/Weekly intervals show a
            // month's budget on its first day where upstream shows nothing.
            return Transaction(
                id: "\(entry.month)-\(entry.categoryId)", accountId: "",
                date: entry.month * 100 + 1, amount: entry.amountCents,
                payeeId: nil, payeeName: nil, categoryId: entry.categoryId, categoryName: nil,
                notes: nil, cleared: true, reconciled: false, transferId: nil,
                isParent: false, parentId: nil, tombstone: false,
                sortOrder: nil, importedPayee: nil)
        }
    }

    // MARK: - Two-ring donut (groupBy CategoryGroup)

    /// Upstream grouped-spreadsheet.ts + DonutGraph.tsx adjustedGroupData:
    /// the inner ring is the category groups in store order (the synthetic
    /// rows form "Uncategorized & Off budget"), each group's value being the
    /// sum of its visible categories so the rings line up; zero groups drop
    /// out, and groups and their categories sort by the same rule.
    private static func twoRingDonut(
        _ rows: [Row], context: ReportContext,
        categoriesById: [String: Category], sortBy: String,
        locale: Locale, bundle: Bundle
    ) -> CustomReportData.Kind {
        struct Group { let name: String; let total: Double; let members: [Row] }
        let order = context.groups.map { ($0.id, $0.name) }
            + [(Synthetic.uncategorized, ReportStrings.text(
                "Uncategorized & Off budget", locale: locale, bundle: bundle))]
        var groups: [Group] = order.compactMap { entry -> Group? in
            let (id, name) = entry
            let members = sorted(
                rows.filter { $0.total > 0 && (categoriesById[$0.key]?.groupId ?? Synthetic.uncategorized) == id },
                by: sortBy, total: \.total, name: \.name, locale: locale)
            guard !members.isEmpty else { return nil }
            return Group(name: name, total: members.map(\.total).reduce(0, +), members: members)
        }
        groups = sorted(groups, by: sortBy, total: \.total, name: \.name, locale: locale)
        return .donut(
            slices: groups.enumerated().flatMap { gi, group in
                group.members.map { .init(label: $0.name, valueUnits: $0.total, group: gi) }
            },
            groups: groups.map { .init(label: $0.name, valueUnits: $0.total) })
    }

    // MARK: - Interval bucketing

    private struct BucketDef { let key: Int; let label: String }

    /// Bucket key: Daily = YYYYMMDD, Weekly = YYYYMMDD of week start,
    /// Monthly = YYYYMM, Yearly = YYYY.
    private static func bucketKey(forYMD ymd: Int, interval: String, firstDayOfWeekIdx: Int) -> Int {
        switch interval {
        case "Daily": return ymd
        case "Weekly":
            let date = dateFrom(ymd)
            return ymdInt(from: ReportDateRange.weekStart(of: date, firstDayOfWeekIdx: firstDayOfWeekIdx))
        case "Yearly": return ymd / 10000
        default: return ymd / 100   // Monthly
        }
    }

    private static func intervalBuckets(
        from start: Date, to end: Date, interval: String, firstDayOfWeekIdx: Int,
        locale: Locale
    ) -> [BucketDef] {
        var out: [BucketDef] = []
        switch interval {
        case "Daily":
            var d = cal.startOfDay(for: start)
            while d <= end {
                out.append(.init(key: ymdInt(from: d), label: dayFormatter(locale: locale).string(from: d)))
                d = cal.date(byAdding: .day, value: 1, to: d)!
            }
        case "Weekly":
            var d = ReportDateRange.weekStart(of: start, firstDayOfWeekIdx: firstDayOfWeekIdx)
            let last = ReportDateRange.weekStart(of: end, firstDayOfWeekIdx: firstDayOfWeekIdx)
            while d <= last {
                out.append(.init(key: ymdInt(from: d), label: dayFormatter(locale: locale).string(from: d)))
                d = cal.date(byAdding: .day, value: 7, to: d)!
            }
        case "Yearly":
            var y = cal.component(.year, from: start)
            let lastY = cal.component(.year, from: end)
            while y <= lastY {
                let d = cal.date(from: DateComponents(year: y, month: 1, day: 1))!
                out.append(.init(key: y, label: yearFormatter(locale: locale).string(from: d)))
                y += 1
            }
        default: // Monthly — label "MMM ''yy" → Sep '25 (upstream intervalFormat)
            let startC = cal.dateComponents([.year, .month], from: start)
            var d = cal.date(from: DateComponents(year: startC.year, month: startC.month, day: 1))!
            let endC = cal.dateComponents([.year, .month], from: end)
            let last = cal.date(from: DateComponents(year: endC.year, month: endC.month, day: 1))!
            while d <= last {
                let mc = cal.dateComponents([.year, .month], from: d)
                out.append(.init(key: (mc.year ?? 0) * 100 + (mc.month ?? 0),
                                 label: monthFormatter(locale: locale).string(from: d)))
                d = cal.date(byAdding: .month, value: 1, to: d)!
            }
        }
        return out
    }

    // MARK: - Dates

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static func dayFormatter(locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = locale
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }

    private static func monthFormatter(locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "MMM ''yy"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = locale
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }

    private static func yearFormatter(locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = locale
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }

    private static func localizedRangeLabel(_ value: String, locale: Locale, bundle: Bundle) -> String {
        switch value {
        case "All time": return ReportStrings.text("All Time", locale: locale, bundle: bundle)
        case "Year to date": return ReportStrings.text("Year to date", locale: locale, bundle: bundle)
        default: return value
        }
    }

    private static func dateFrom(_ ymd: Int) -> Date {
        cal.date(from: DateComponents(year: ymd / 10000, month: (ymd % 10000) / 100, day: ymd % 100))!
    }

    private static func ymdInt(from date: Date) -> Int {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }
}
