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
        let digits = value.replacingOccurrences(of: "-", with: "")
        guard let target = Int(digits) else { return nil }

        switch (op, digits.count) {
        case ("is", 8): return transactionDate == target
        case ("is", 6): return transactionDate / 100 == target        // YYYY-MM
        case ("is", 4): return transactionDate / 10000 == target      // YYYY
        case ("isapprox", 8):
            // Upstream widens an exact date by ±2 days.
            guard let targetDate = date(from: target),
                  let txDate = date(from: transactionDate) else { return nil }
            return abs(txDate.timeIntervalSince(targetDate)) <= 2 * 86_400 + 1
        case ("gt", 8): return transactionDate > target
        case ("gte", 8): return transactionDate >= target
        case ("lt", 8): return transactionDate < target
        case ("lte", 8): return transactionDate <= target
        default:
            // Comparison ops require an exact date upstream; month/year values
            // fail `Condition`'s parse assertions and the rule never loads.
            return nil
        }
    }

    private static func date(from yyyymmdd: Int) -> Date? {
        var components = DateComponents()
        components.year = yyyymmdd / 10000
        components.month = (yyyymmdd % 10000) / 100
        components.day = yyyymmdd % 100
        return Calendar.current.date(from: components)
    }
}
