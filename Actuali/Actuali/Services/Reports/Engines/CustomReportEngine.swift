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

    enum Kind: Equatable {
        case bars([Bar], signed: Bool)   // signed → color bars by sign (Net)
        case stacked(Stacked)
        case table([TableRow])
        case unsupported(String)
    }
    var kind: Kind
}

/// Port of the webapp's custom-spreadsheet.ts for the option subset Actuali
/// renders. Everything computes from the shared reports transaction array;
/// configs outside the supported matrix return `.unsupported` naming the
/// offending option so the card can explain itself.
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
    }

    static func compute(
        config: CustomReportConfig?,
        transactions: [Transaction],
        reportContext: ReportContext,
        filterContext: ConditionsFilter.Context,
        today: Date
    ) -> CustomReportData {
        guard let config else {
            return CustomReportData(name: "Custom Report", rangeLabel: "",
                                    kind: .unsupported("Report not found — try syncing"))
        }
        var data = CustomReportData(name: config.name,
                                    rangeLabel: config.dateStatic ? "" : (config.dateRange ?? "All time"),
                                    kind: .unsupported(""))

        // Supported-matrix guard: name the first offending option.
        for (value, supported, label) in [
            (config.mode, ["total", "time"], "mode"),
            (config.groupBy, ["Category", "Group", "Interval"], "group by"),
            (config.balanceType, ["Payment", "Deposit", "Net"], "balance type"),
            (config.interval, ["Daily", "Weekly", "Monthly", "Yearly"], "interval"),
            (config.graphType, ["BarGraph", "StackedBarGraph", "TableGraph"], "graph"),
        ] where !supported.contains(value) {
            data.kind = .unsupported("\(value) \(label) isn't supported yet")
            return data
        }

        // Date range from actual history.
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

        // Filter (upstream: conditions, then filterHiddenItems) — single pass.
        // Category resolves through the lookup, mirroring upstream's query
        // join: a dangling categoryId behaves exactly like no category.
        let pool = live.filter { tx in
            guard tx.date >= startYMD && tx.date <= endYMD else { return false }
            guard ConditionsFilter.matches(transaction: tx, conditions: config.conditions,
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
                                      firstDayOfWeekIdx: reportContext.firstDayOfWeekIdx)
        let bucketIndex = Dictionary(uniqueKeysWithValues:
            buckets.enumerated().map { ($0.element.key, $0.offset) })
        let labels = buckets.map(\.label)

        // Accumulate assets/debts per (group, bucket). Group key "" = whole row
        // (groupBy Interval).
        struct Cell { var assets = 0; var debts = 0 }
        var cells: [String: [Int: Cell]] = [:]   // groupKey -> bucketIdx -> sums
        for tx in pool {
            let key = bucketKey(forYMD: tx.date, interval: config.interval,
                                firstDayOfWeekIdx: reportContext.firstDayOfWeekIdx)
            guard let idx = bucketIndex[key] else { continue }
            // Upstream filterHiddenItems: only categorized on-budget txs land
            // on regular rows; everything else goes to the synthetic rows —
            // off-budget txs (even categorized ones) to "Off budget", then
            // uncategorized transfers to "Transfers", the rest to
            // "Uncategorized". Group mode folds all three into one group.
            let category = tx.categoryId.flatMap { categoriesById[$0] }
            let offBudget = reportContext.offBudgetAccountIds.contains(tx.accountId)
            let groupKey: String
            switch config.groupBy {
            case "Category":
                if let category, !offBudget { groupKey = category.id }
                else if offBudget { groupKey = Synthetic.offBudget }
                else if tx.transferAcct != nil { groupKey = Synthetic.transfer }
                else { groupKey = Synthetic.uncategorized }
            case "Group":
                if let category, !offBudget { groupKey = category.groupId }
                else { groupKey = Synthetic.uncategorized }
            default: groupKey = ""   // Interval
            }
            var cell = cells[groupKey, default: [:]][idx, default: Cell()]
            if tx.amount > 0 { cell.assets += tx.amount } else { cell.debts += tx.amount }
            cells[groupKey, default: [:]][idx] = cell
        }

        func value(_ cell: Cell) -> Double {
            switch config.balanceType {
            case "Payment": return Double(-cell.debts) / 100    // |debts|
            case "Deposit": return Double(cell.assets) / 100
            default:        return Double(cell.assets + cell.debts) / 100  // Net, signed
            }
        }

        // groupBy Interval → one row per bucket (web renders intervalData here).
        if config.groupBy == "Interval" {
            let row = cells[""] ?? [:]
            let values = labels.indices.map { row[$0].map(value) ?? 0 }
            if config.graphType == "TableGraph" {
                data.kind = .table(zip(labels, values).map { .init(name: $0, totalUnits: $1) })
            } else {
                data.kind = .bars(zip(labels, values).map { .init(label: $0, valueUnits: $1) },
                                  signed: config.balanceType == "Net")
            }
            return data
        }

        // Named groups in budget order. Upstream (ReportOptions.categoryLists)
        // always appends the synthetic rows; when their txs are filtered out
        // they total zero and fall to the showEmpty filter like any other row.
        let orderedGroups: [(key: String, name: String)]
        if config.groupBy == "Category" {
            orderedGroups = reportContext.categories.map { ($0.id, $0.name) } + [
                (Synthetic.uncategorized, "Uncategorized"),
                (Synthetic.offBudget, "Off budget"),
                (Synthetic.transfer, "Transfers"),
            ]
        } else {
            orderedGroups = reportContext.groups.map { ($0.id, $0.name) }
                + [(Synthetic.uncategorized, "Uncategorized & Off budget")]
        }

        struct GroupTotal { let key: String; let name: String; let total: Double; let perBucket: [Double] }
        var totals: [GroupTotal] = orderedGroups.map { group in
            let row = cells[group.key] ?? [:]
            let perBucket = (0..<buckets.count).map { row[$0].map(value) ?? 0 }
            return GroupTotal(key: group.key, name: group.name,
                              total: perBucket.reduce(0, +), perBucket: perBucket)
        }
        if !config.showEmpty {
            totals = totals.filter { $0.total != 0 || $0.perBucket.contains { $0 != 0 } }
        }
        switch config.sortBy {
        case "asc":  totals.sort { abs($0.total) < abs($1.total) }
        case "name": totals.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "budget": break                       // keep budget order
        default:     totals.sort { abs($0.total) > abs($1.total) }  // desc
        }

        if config.graphType == "TableGraph" {
            data.kind = .table(totals.map { .init(name: $0.name, totalUnits: $0.total) })
        } else if config.mode == "time" {
            data.kind = .stacked(.init(intervalLabels: labels,
                                       seriesNames: totals.map(\.name),
                                       values: totals.map(\.perBucket)))
        } else {
            data.kind = .bars(totals.map { .init(label: $0.name, valueUnits: $0.total) },
                              signed: config.balanceType == "Net")
        }
        return data
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
        from start: Date, to end: Date, interval: String, firstDayOfWeekIdx: Int
    ) -> [BucketDef] {
        var out: [BucketDef] = []
        switch interval {
        case "Daily":
            var d = cal.startOfDay(for: start)
            while d <= end {
                out.append(.init(key: ymdInt(from: d), label: dayFormatter.string(from: d)))
                d = cal.date(byAdding: .day, value: 1, to: d)!
            }
        case "Weekly":
            var d = ReportDateRange.weekStart(of: start, firstDayOfWeekIdx: firstDayOfWeekIdx)
            let last = ReportDateRange.weekStart(of: end, firstDayOfWeekIdx: firstDayOfWeekIdx)
            while d <= last {
                out.append(.init(key: ymdInt(from: d), label: dayFormatter.string(from: d)))
                d = cal.date(byAdding: .day, value: 7, to: d)!
            }
        case "Yearly":
            var y = cal.component(.year, from: start)
            let lastY = cal.component(.year, from: end)
            while y <= lastY {
                let d = cal.date(from: DateComponents(year: y, month: 1, day: 1))!
                out.append(.init(key: y, label: yearFormatter.string(from: d)))
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
                                 label: monthFormatter.string(from: d)))
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

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM ''yy"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func dateFrom(_ ymd: Int) -> Date {
        cal.date(from: DateComponents(year: ymd / 10000, month: (ymd % 10000) / 100, day: ymd % 100))!
    }

    private static func ymdInt(from date: Date) -> Int {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }
}
