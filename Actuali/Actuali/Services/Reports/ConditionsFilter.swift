import Foundation

enum ConditionsFilter {

    /// Budget-level context some conditions need: `onBudget`/`offBudget` ops
    /// and account-name matching can't be answered from the transaction alone.
    struct Context {
        var offBudgetAccountIds: Set<String> = []
        var accountNames: [String: String] = [:]  // account id -> name

        static let empty = Context()
    }

    /// Returns `true` if the transaction matches the condition set under the
    /// given combinator. Empty/nil conditions always match.
    ///
    /// Mirrors upstream `conditionsToAQL` (transaction-rules.ts). Conditions
    /// with a `customName` are saved-filter references; upstream drops them
    /// before building filters, so we skip them too.
    static func matches(
        transaction: Transaction,
        conditions: [WidgetRuleCondition]?,
        op: String?,
        context: Context = .empty
    ) -> Bool {
        let active = (conditions ?? []).filter { $0.customName == nil }
        guard !active.isEmpty else { return true }
        let combinator = (op ?? "and").lowercased()
        if combinator == "or" {
            return active.contains { matches(transaction: transaction, condition: $0, context: context) }
        }
        return active.allSatisfy { matches(transaction: transaction, condition: $0, context: context) }
    }

    // MARK: - Single condition

    private enum FieldType {
        case id, string, number, date, boolean, transfer, parent
    }

    private struct AmountOptions: Decodable {
        var inflow: Bool?
        var outflow: Bool?
    }

    private static func fieldType(_ field: String) -> FieldType? {
        switch field {
        case "category", "account", "payee", "description": return .id
        case "notes", "imported_payee": return .string
        case "amount", "amount-inflow", "amount-outflow": return .number
        case "date": return .date
        case "cleared", "reconciled": return .boolean
        case "transfer": return .transfer
        case "parent": return .parent
        default: return nil
        }
    }

    private static func matches(transaction tx: Transaction, condition c: WidgetRuleCondition, context: Context) -> Bool {
        guard let type = fieldType(c.field) else {
            // Unknown fields behave like upstream's invalid conditions, which
            // are dropped from the filter set: pass everything through.
            return true
        }

        switch type {
        case .number:
            return matchNumber(tx, c)
        case .date:
            return matchDate(tx, c)
        case .id:
            return matchId(tx, c, context: context)
        case .string:
            return matchString(tx, c)
        case .boolean:
            let txValue = c.field == "cleared" ? tx.cleared : tx.reconciled
            return matchBool(txValue, c)
        case .transfer:
            return matchBool(tx.transferId != nil, c)
        case .parent:
            return matchBool(tx.isParent, c)
        }
    }

    private static func matchBool(_ txValue: Bool, _ c: WidgetRuleCondition) -> Bool {
        guard c.op == "is", let want = decodeBool(c.value) else { return true }
        return txValue == want
    }

    // MARK: - Amount conditions

    private static func matchNumber(_ tx: Transaction, _ c: WidgetRuleCondition) -> Bool {
        var options = decodeAmountOptions(c.options)
        // Legacy serialized field names carry the direction in the field itself.
        if c.field == "amount-inflow" { options.inflow = true }
        if c.field == "amount-outflow" { options.outflow = true }

        // "isbetween" ignores inflow/outflow and compares the raw amount,
        // matching upstream (it bypasses the option-aware `apply` helper).
        if c.op == "isbetween" {
            guard let range = decodeBetween(c.value) else { return true }
            let amount = Double(tx.amount)
            return amount >= min(range.0, range.1) && amount <= max(range.0, range.1)
        }

        guard let value = decodeNumber(c.value) else { return true }

        // Directional filters gate on sign and compare the magnitude:
        // outflow negates the (negative) amount so the user-entered positive
        // value lines up.
        func apply(_ cmp: (Double, Double) -> Bool) -> Bool {
            if options.outflow == true {
                return tx.amount < 0 && cmp(Double(-tx.amount), value)
            }
            if options.inflow == true {
                return tx.amount > 0 && cmp(Double(tx.amount), value)
            }
            return cmp(Double(tx.amount), value)
        }

        switch c.op {
        case "is": return apply(==)
        case "isapprox":
            let threshold = (abs(value) * 0.075).rounded()
            return apply { magnitude, _ in magnitude >= value - threshold && magnitude <= value + threshold }
        case "gt": return apply(>)
        case "gte": return apply(>=)
        case "lt": return apply(<)
        case "lte": return apply(<=)
        default: return true
        }
    }

    // MARK: - Date conditions

    /// Condition dates are strings: "yyyy-MM-dd", "yyyy-MM", or "yyyy".
    /// Transactions store dates as YYYYMMDD ints. Recurring-date conditions
    /// (objects with a frequency) are not supported and pass through.
    private static func matchDate(_ tx: Transaction, _ c: WidgetRuleCondition) -> Bool {
        guard let s = decodeString(c.value) else { return true }
        let digits = s.replacingOccurrences(of: "-", with: "")
        guard let value = Int(digits) else { return true }

        switch (c.op, digits.count) {
        case ("is", 8): return tx.date == value
        case ("is", 6): return tx.date / 100 == value      // month
        case ("is", 4): return tx.date / 10000 == value    // year
        case ("isapprox", 8):
            guard let target = ymdToDate(value), let txDate = ymdToDate(tx.date) else { return false }
            return abs(txDate.timeIntervalSince(target)) <= 2 * 86_400 + 1
        case ("gt", 8): return tx.date > value
        case ("gte", 8): return tx.date >= value
        case ("lt", 8): return tx.date < value
        case ("lte", 8): return tx.date <= value
        default:
            // Upstream rejects month/year values for comparison ops at parse
            // time, dropping the condition entirely.
            return true
        }
    }

    // MARK: - Id conditions (category / account / payee)

    private static func matchId(_ tx: Transaction, _ c: WidgetRuleCondition, context: Context) -> Bool {
        let txId: String?
        switch c.field {
        case "category": txId = tx.categoryId
        case "account": txId = tx.accountId
        default: txId = tx.payeeId  // "payee" / legacy "description"
        }

        switch c.op {
        case "is":
            let condValue = decodeString(c.value)
            if condValue == nil || condValue == "" {
                // "is nothing" matches missing values. For category, upstream
                // additionally excludes transfers and split parents
                // (conditionSpecialCases) so transfer legs don't count as
                // "uncategorized".
                let isEmpty = (txId ?? "").isEmpty
                if c.field == "category" {
                    return isEmpty && tx.transferId == nil && !tx.isParent
                }
                return isEmpty
            }
            return txId == condValue
        case "isNot":
            let condValue = decodeString(c.value)
            if condValue == nil || condValue == "" {
                return !(txId ?? "").isEmpty
            }
            // SQL `!=` lets NULL rows through (`x != v OR x IS NULL`).
            return txId != condValue
        case "oneOf":
            guard let list = decodeStringArray(c.value), !list.isEmpty else { return false }
            guard let txId, !txId.isEmpty else { return false }
            return list.contains(txId)
        case "notOneOf":
            guard let list = decodeStringArray(c.value), !list.isEmpty else { return false }
            guard let txId, !txId.isEmpty else { return true }  // NULL passes $ne
            return !list.contains(txId)
        case "contains", "doesNotContain", "matches":
            // Id fields match against the referenced row's *name*.
            let name: String?
            switch c.field {
            case "category": name = tx.categoryName
            case "account": name = context.accountNames[tx.accountId]
            default: name = tx.payeeName
            }
            return matchText(name, op: c.op, value: decodeString(c.value))
        case "onBudget":
            return !context.offBudgetAccountIds.contains(tx.accountId)
        case "offBudget":
            return context.offBudgetAccountIds.contains(tx.accountId)
        default:
            return true
        }
    }

    // MARK: - String conditions (notes / imported_payee)

    private static func matchString(_ tx: Transaction, _ c: WidgetRuleCondition) -> Bool {
        let txValue = c.field == "notes" ? tx.notes : tx.importedPayee

        switch c.op {
        case "is":
            let condValue = decodeString(c.value)
            if condValue == nil || condValue == "" {
                return (txValue ?? "").isEmpty
            }
            return txValue?.lowercased() == condValue?.lowercased()
        case "isNot":
            let condValue = decodeString(c.value)
            if condValue == nil || condValue == "" {
                return !(txValue ?? "").isEmpty
            }
            return txValue?.lowercased() != condValue?.lowercased()
        case "oneOf":
            guard let list = decodeStringArray(c.value), !list.isEmpty,
                  let txValue else { return false }
            return list.map { $0.lowercased() }.contains(txValue.lowercased())
        case "notOneOf":
            guard let list = decodeStringArray(c.value), !list.isEmpty else { return false }
            guard let txValue else { return true }
            return !list.map { $0.lowercased() }.contains(txValue.lowercased())
        case "contains", "doesNotContain", "matches":
            return matchText(txValue, op: c.op, value: decodeString(c.value))
        case "hasTags", "hasAnyTag":
            let tags = extractTags(decodeString(c.value) ?? "")
            guard !tags.isEmpty else { return false }
            guard let notes = txValue else { return false }
            let hit = { (tag: String) in notesContainTag(notes, tag: tag) }
            return c.op == "hasTags" ? tags.allSatisfy(hit) : tags.contains(where: hit)
        default:
            return true
        }
    }

    /// contains / doesNotContain / matches share NULL semantics with SQL:
    /// `NOT LIKE` and negated regex let NULL rows through.
    private static func matchText(_ haystack: String?, op: String, value: String?) -> Bool {
        guard let value, !value.isEmpty else { return true }
        switch op {
        case "contains":
            guard let haystack else { return false }
            return haystack.localizedCaseInsensitiveContains(value)
        case "doesNotContain":
            guard let haystack else { return true }
            return !haystack.localizedCaseInsensitiveContains(value)
        case "matches":
            guard let haystack else { return false }
            guard let regex = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else {
                // Upstream would fail the whole query on a bad regex; be
                // permissive instead of blanking the widget.
                return true
            }
            let range = NSRange(haystack.startIndex..., in: haystack)
            return regex.firstMatch(in: haystack, range: range) != nil
        default:
            return true
        }
    }

    /// Port of upstream `extractTagsForFilter`: every whitespace-separated
    /// token (leading `#`s stripped) becomes a `#token` tag.
    private static func extractTags(_ value: String) -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for token in value.split(whereSeparator: { $0.isWhitespace || $0 == "#" }) {
            let tag = "#" + token
            if seen.insert(tag).inserted { tags.append(tag) }
        }
        return tags
    }

    /// Matches upstream's tag pattern `(?<!#)tag([\s#]|$)`: the tag must not
    /// be preceded by an extra `#` and must end at whitespace, another tag,
    /// or the end of the notes. Case-sensitive, like upstream.
    private static func notesContainTag(_ notes: String, tag: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        guard let regex = try? NSRegularExpression(pattern: "(?<!#)\(escaped)([\\s#]|$)") else { return false }
        let range = NSRange(notes.startIndex..., in: notes)
        return regex.firstMatch(in: notes, range: range) != nil
    }

    // MARK: - Value decoding

    private static func decodeBool(_ value: AnyCodable?) -> Bool? {
        guard let value else { return nil }
        return try? JSONDecoder().decode(Bool.self, from: value.raw)
    }

    private static func decodeString(_ value: AnyCodable?) -> String? {
        guard let value else { return nil }
        return try? JSONDecoder().decode(String.self, from: value.raw)
    }

    private static func decodeNumber(_ value: AnyCodable?) -> Double? {
        guard let value else { return nil }
        return try? JSONDecoder().decode(Double.self, from: value.raw)
    }

    private static func decodeStringArray(_ value: AnyCodable?) -> [String]? {
        guard let value else { return nil }
        if let arr = try? JSONDecoder().decode([String].self, from: value.raw) { return arr }
        if let arr = try? JSONDecoder().decode([Int].self, from: value.raw) { return arr.map(String.init) }
        return nil
    }

    private static func decodeBetween(_ value: AnyCodable?) -> (Double, Double)? {
        struct Between: Decodable { let num1: Double; let num2: Double }
        guard let value, let b = try? JSONDecoder().decode(Between.self, from: value.raw) else { return nil }
        return (b.num1, b.num2)
    }

    private static func decodeAmountOptions(_ value: AnyCodable?) -> AmountOptions {
        guard let value,
              let opts = try? JSONDecoder().decode(AmountOptions.self, from: value.raw) else {
            return AmountOptions(inflow: nil, outflow: nil)
        }
        return opts
    }

    private static func ymdToDate(_ ymd: Int) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: ymd / 10000, month: (ymd % 10000) / 100, day: ymd % 100))
    }
}
