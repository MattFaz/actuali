import Foundation

/// Date-condition semantics shared by the rules engine and the report filters.
/// Condition values are strings (`"2026-05-03"`, `"2026-05"`, `"2026"`);
/// transactions store dates as YYYYMMDD ints.
///
/// Returns `nil` when the condition can't be evaluated (unparseable value, or
/// an op/precision combination upstream rejects at parse time). Callers decide
/// what that means: the engine treats it as "no match", the report filters as
/// "condition dropped", which is what each does upstream.
enum RuleDateMatcher {

    static func matches(transactionDate: Int, op: String, value: String) -> Bool? {
        guard let targetDate = CanonicalDateParser.parse(value) else { return nil }
        let precision = value.count
        let components = calendar.dateComponents([.year, .month, .day], from: targetDate)
        guard let year = components.year else { return nil }
        let target = year * 10_000 + (components.month ?? 1) * 100 + (components.day ?? 1)

        switch (op, precision) {
        case ("is", 10): return transactionDate == target
        case ("is", 7): return transactionDate / 100 == target / 100        // YYYY-MM
        case ("is", 4): return transactionDate / 10000 == target / 10000      // YYYY
        case ("isapprox", 10):
            // Upstream widens an exact date by ±2 days.
            guard let targetDate = date(from: target),
                  let txDate = date(from: transactionDate) else { return nil }
            return abs(txDate.timeIntervalSince(targetDate)) <= 2 * 86_400 + 1
        case ("gt", 10): return transactionDate > target
        case ("gte", 10): return transactionDate >= target
        case ("lt", 10): return transactionDate < target
        case ("lte", 10): return transactionDate <= target
        default:
            // Comparison ops require an exact date upstream; month/year values
            // fail `Condition`'s parse assertions and the rule never loads.
            return nil
        }
    }

    /// Fixed UTC Gregorian calendar, not `Calendar.current`: the ±2 day window
    /// has to be exactly 2 × 86,400s. A local calendar makes a DST day 23 or 25
    /// hours long, which pushes a legitimately-two-days-apart pair over the
    /// threshold, and makes results depend on the device's timezone.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    private static func date(from yyyymmdd: Int) -> Date? {
        var components = DateComponents()
        components.year = yyyymmdd / 10000
        components.month = (yyyymmdd % 10000) / 100
        components.day = yyyymmdd % 100
        guard let date = calendar.date(from: components) else { return nil }
        let parsed = calendar.dateComponents([.year, .month, .day], from: date)
        guard parsed.year == components.year,
              parsed.month == components.month,
              parsed.day == components.day else { return nil }
        return date
    }
}
