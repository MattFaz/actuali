import Foundation

struct SummaryData: Equatable {
    enum Kind: Equatable {
        case currency    // value is cents
        case percentage  // value is a percent (e.g. 42.45)
    }

    let value: Double
    let kind: Kind

    /// Rounded cents for currency values; kept for display convenience.
    var totalCents: Int { Int(value.rounded()) }

    static let zero = SummaryData(value: 0, kind: .currency)
}

/// Port of the webapp's summary-spreadsheet.ts. The widget's `content`
/// selects how the filtered total is reduced: raw sum, average per
/// month/year/transaction, or a percentage of a second filtered total.
enum SummaryEngine {

    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    static func compute(
        meta: SummaryMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context = .empty
    ) -> SummaryData {
        guard let meta else { return .zero }

        var (start, end) = TimeFrame.resolve(meta.timeFrame, asOf: today)
        // Upstream clamps the range the same way regardless of mode: the
        // start snaps to the first of its month, and a range ending in the
        // current month ends *today* (this also keeps the avg-per-month
        // divisor from counting days that haven't happened yet).
        start = monthStart(of: start)
        if calendar.isDate(end, equalTo: today, toGranularity: .month) {
            end = today
        }
        let startYMD = ymdInt(from: start)
        let endYMD = ymdInt(from: end)

        let filtered = transactions
            .filter { !$0.tombstone }
            .filter { $0.date >= startYMD && $0.date <= endYMD }
            .filter { ConditionsFilter.matches(transaction: $0, conditions: meta.conditions, op: meta.conditionsOp, context: context) }

        let total = Double(filtered.reduce(0) { $0 + $1.amount })
        let content = meta.content

        switch content?.type ?? "sum" {
        case "avgPerTransact":
            return SummaryData(value: filtered.isEmpty ? 0 : total / Double(filtered.count), kind: .currency)

        case "avgPerMonth":
            guard !filtered.isEmpty else { return .zero }
            // months between start month and end month, plus the elapsed
            // fraction of the final month (upstream calculatePerMonth).
            let wholeMonths = calendar.dateComponents([.month], from: monthStart(of: start), to: monthStart(of: end)).month ?? 0
            let dayOfMonth = calendar.component(.day, from: end)
            let daysInMonth = calendar.range(of: .day, in: .month, for: end)?.count ?? 30
            let numMonths = Double(wholeMonths) + Double(dayOfMonth) / Double(daysInMonth)
            return SummaryData(value: numMonths > 0 ? total / numMonths : 0, kind: .currency)

        case "avgPerYear":
            guard !filtered.isEmpty else { return .zero }
            let totalDays = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
            let numYears = Double(totalDays) / 365.25
            return SummaryData(value: numYears > 0 ? total / numYears : 0, kind: .currency)

        case "percentage":
            var divisorPool = transactions.filter { !$0.tombstone }
            if !(content?.divisorAllTimeDateRange ?? false) {
                divisorPool = divisorPool.filter { $0.date >= startYMD && $0.date <= endYMD }
            }
            let divisor = Double(
                divisorPool
                    .filter {
                        ConditionsFilter.matches(
                            transaction: $0,
                            conditions: content?.divisorConditions,
                            op: content?.divisorConditionsOp,
                            context: context
                        )
                    }
                    .reduce(0) { $0 + $1.amount }
            )
            guard divisor != 0 else { return SummaryData(value: 0, kind: .percentage) }
            return SummaryData(value: (total / divisor * 10000).rounded() / 100, kind: .percentage)

        default:  // "sum" and anything unrecognized
            return SummaryData(value: total, kind: .currency)
        }
    }

    private static func monthStart(of date: Date) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? date
    }

    private static func ymdInt(from date: Date) -> Int {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return (comps.year ?? 0) * 10000 + (comps.month ?? 0) * 100 + (comps.day ?? 0)
    }
}
