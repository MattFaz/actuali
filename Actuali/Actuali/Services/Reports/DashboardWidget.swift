import Foundation

// MARK: - TimeFrame (shared by most widgets)

struct WidgetTimeFrame: Codable, Equatable {
    let start: String?
    let end: String?
    let mode: Mode?

    enum Mode: String, Codable {
        case slidingWindow = "sliding-window"
        case `static`
        case full
        case lastMonth
        case lastYear
        case yearToDate
        case priorYearToDate
    }
}

// MARK: - Rule Condition (subset used by widgets)

struct WidgetRuleCondition: Codable, Equatable {
    let op: String
    let field: String
    let value: AnyCodable?
    let options: AnyCodable?
    /// Present on saved-filter references; upstream drops these conditions
    /// before filtering, so engines must skip them.
    let customName: String?
}

/// Untyped Codable wrapper for nested JSON values. Stores the original
/// JSON-encoded data so the value can be re-emitted unchanged.
struct AnyCodable: Codable, Equatable {
    let raw: Data  // original JSON bytes (e.g. "\"groceries\"", "42", "true", "null", arrays, objects)

    init(rawJSON: Data) { self.raw = rawJSON }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            raw = Data("null".utf8)
        } else if let s = try? container.decode(String.self) {
            raw = try JSONEncoder().encode(s)
        } else if let b = try? container.decode(Bool.self) {
            raw = try JSONEncoder().encode(b)
        } else if let i = try? container.decode(Int.self) {
            raw = try JSONEncoder().encode(i)
        } else if let d = try? container.decode(Double.self) {
            raw = try JSONEncoder().encode(d)
        } else if let arr = try? container.decode([AnyCodable].self) {
            let encoded = "[" + arr.map { String(data: $0.raw, encoding: .utf8) ?? "null" }.joined(separator: ",") + "]"
            raw = Data(encoded.utf8)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            let pairs = dict.map { key, value -> String in
                let v = String(data: value.raw, encoding: .utf8) ?? "null"
                let escapedKey = (try? String(data: JSONEncoder().encode(key), encoding: .utf8)) ?? "\"\(key)\""
                return "\(escapedKey):\(v)"
            }
            raw = Data(("{" + pairs.joined(separator: ",") + "}").utf8)
        } else {
            raw = Data("null".utf8)
        }
    }

    func encode(to encoder: Encoder) throws {
        // Re-emit the raw JSON. We do this by decoding into a typed shadow.
        var container = encoder.singleValueContainer()
        if let s = try? JSONDecoder().decode(String.self, from: raw) {
            try container.encode(s)
        } else if let b = try? JSONDecoder().decode(Bool.self, from: raw) {
            try container.encode(b)
        } else if let i = try? JSONDecoder().decode(Int.self, from: raw) {
            try container.encode(i)
        } else if let d = try? JSONDecoder().decode(Double.self, from: raw) {
            try container.encode(d)
        } else {
            try container.encodeNil()
        }
    }
}

// MARK: - Per-widget meta structs

struct SummaryMeta: Codable, Equatable {
    let name: String?
    let timeFrame: WidgetTimeFrame?
    let conditions: [WidgetRuleCondition]?
    let conditionsOp: String?
    let content: SummaryContent?

    private enum CodingKeys: String, CodingKey {
        case name, timeFrame, conditions, conditionsOp, content
    }

    init(
        name: String?,
        timeFrame: WidgetTimeFrame?,
        conditions: [WidgetRuleCondition]?,
        conditionsOp: String?,
        content: SummaryContent?
    ) {
        self.name = name
        self.timeFrame = timeFrame
        self.conditions = conditions
        self.conditionsOp = conditionsOp
        self.content = content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        timeFrame = try container.decodeIfPresent(WidgetTimeFrame.self, forKey: .timeFrame)
        conditions = try container.decodeIfPresent([WidgetRuleCondition].self, forKey: .conditions)
        conditionsOp = try container.decodeIfPresent(String.self, forKey: .conditionsOp)
        // Upstream double-encodes content as a JSON string
        // ("{\"type\":\"sum\"}"); tolerate an inline object as well.
        if let string = try? container.decode(String.self, forKey: .content),
           let data = string.data(using: .utf8) {
            content = try? JSONDecoder().decode(SummaryContent.self, from: data)
        } else {
            content = try? container.decodeIfPresent(SummaryContent.self, forKey: .content)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(timeFrame, forKey: .timeFrame)
        try container.encodeIfPresent(conditions, forKey: .conditions)
        try container.encodeIfPresent(conditionsOp, forKey: .conditionsOp)
        if let content,
           let data = try? JSONEncoder().encode(content),
           let string = String(data: data, encoding: .utf8) {
            try container.encode(string, forKey: .content)
        }
    }
}

/// The summary widget's display mode. `type` is one of `sum`, `avgPerMonth`,
/// `avgPerYear`, `avgPerTransact`, or `percentage`; the divisor fields only
/// apply to `percentage`.
struct SummaryContent: Codable, Equatable {
    let type: String?
    let divisorConditions: [WidgetRuleCondition]?
    let divisorConditionsOp: String?
    let divisorAllTimeDateRange: Bool?
}

struct NetWorthMeta: Codable, Equatable {
    let name: String?
    let timeFrame: WidgetTimeFrame?
    let conditions: [WidgetRuleCondition]?
    let conditionsOp: String?
    let interval: Interval?
    let mode: Mode?

    enum Interval: String, Codable {
        case daily = "Daily"
        case weekly = "Weekly"
        case monthly = "Monthly"
        case yearly = "Yearly"
    }

    enum Mode: String, Codable {
        case trend
        case stacked
    }
}

struct CashFlowMeta: Codable, Equatable {
    let name: String?
    let timeFrame: WidgetTimeFrame?
    let conditions: [WidgetRuleCondition]?
    let conditionsOp: String?
    let showBalance: Bool?
}

struct SpendingMeta: Codable, Equatable {
    let name: String?
    let conditions: [WidgetRuleCondition]?
    let conditionsOp: String?
    let compare: String?
    let compareTo: String?
    let isLive: Bool?
    let mode: Mode?

    enum Mode: String, Codable {
        case singleMonth = "single-month"
        case budget
        case average
    }
}

struct MarkdownMeta: Codable, Equatable {
    let content: String
    let textAlign: TextAlign?

    enum TextAlign: String, Codable {
        case left, right, center
    }

    enum CodingKeys: String, CodingKey {
        case content
        case textAlign = "text_align"
    }
}

// MARK: - DashboardWidget enum

enum DashboardWidget: Equatable {
    case summary(id: String, meta: SummaryMeta?)
    case netWorth(id: String, meta: NetWorthMeta?)
    case cashFlow(id: String, meta: CashFlowMeta?)
    case spending(id: String, meta: SpendingMeta?)
    case markdown(id: String, meta: MarkdownMeta)
    case unsupported(id: String, type: String)

    var id: String {
        switch self {
        case .summary(let id, _),
             .netWorth(let id, _),
             .cashFlow(let id, _),
             .spending(let id, _),
             .markdown(let id, _),
             .unsupported(let id, _):
            return id
        }
    }

    var typeLabel: String {
        switch self {
        case .summary: return "Summary"
        case .netWorth: return "Net Worth"
        case .cashFlow: return "Cash Flow"
        case .spending: return "Spending"
        case .markdown: return "Notes"
        case .unsupported(_, let type): return type
        }
    }

    var displayName: String {
        switch self {
        case .summary(_, let meta): return meta?.name ?? typeLabel
        case .netWorth(_, let meta): return meta?.name ?? typeLabel
        case .cashFlow(_, let meta): return meta?.name ?? typeLabel
        case .spending(_, let meta): return meta?.name ?? typeLabel
        case .markdown: return typeLabel
        case .unsupported: return typeLabel
        }
    }

    static func parse(id: String, type: String, metaJSON: String?) -> DashboardWidget {
        func decode<T: Decodable>(_ type: T.Type) -> T? {
            guard let metaJSON, let data = metaJSON.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }

        switch type {
        case "summary-card":
            return .summary(id: id, meta: decode(SummaryMeta.self))
        case "net-worth-card":
            return .netWorth(id: id, meta: decode(NetWorthMeta.self))
        case "cash-flow-card":
            return .cashFlow(id: id, meta: decode(CashFlowMeta.self))
        case "spending-card":
            return .spending(id: id, meta: decode(SpendingMeta.self))
        case "markdown-card":
            if let meta = decode(MarkdownMeta.self) {
                return .markdown(id: id, meta: meta)
            }
            return .unsupported(id: id, type: type)
        default:
            return .unsupported(id: id, type: type)
        }
    }
}
