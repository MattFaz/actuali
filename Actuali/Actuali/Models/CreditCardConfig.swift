import Foundation

/// Synced configuration for a credit card account, persisted in Actual's `preferences` table.
/// Stored under the key `actuali:credit_card:<accountId>` as a JSON string.
struct CreditCardConfig: Codable, Equatable, Hashable, Sendable {
    /// Day of the month the statement closes (1...31).
    var statementDay: Int

    /// Days between the statement closing and the payment due date.
    var dueOffsetDays: Int

    /// Credit limit in cents (positive), or nil if no limit is configured.
    var limit: Int?

    /// Timestamp of when this configuration was last modified.
    var updatedAt: Date

    init(
        statementDay: Int,
        dueOffsetDays: Int = CreditCardCycle.defaultDueOffsetDays,
        limit: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.statementDay = statementDay
        self.dueOffsetDays = dueOffsetDays
        self.limit = limit
        self.updatedAt = updatedAt
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    enum CodingKeys: String, CodingKey {
        case statementDay
        case dueOffsetDays
        case limit
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statementDay = try container.decode(Int.self, forKey: .statementDay)
        dueOffsetDays = try container.decodeIfPresent(Int.self, forKey: .dueOffsetDays) ?? CreditCardCycle.defaultDueOffsetDays
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)

        if let dateString = try container.decodeIfPresent(String.self, forKey: .updatedAt) {
            if let date = Self.iso8601Formatter.date(from: dateString) ?? Self.fallbackISO8601Formatter.date(from: dateString) {
                updatedAt = date
            } else {
                updatedAt = Date()
            }
        } else {
            updatedAt = Date()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(statementDay, forKey: .statementDay)
        try container.encode(dueOffsetDays, forKey: .dueOffsetDays)
        try container.encodeIfPresent(limit, forKey: .limit)
        try container.encode(Self.iso8601Formatter.string(from: updatedAt), forKey: .updatedAt)
    }

    /// Serializes this config to a JSON string.
    func toJSONString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deserializes a config from a JSON string.
    static func from(jsonString: String) -> CreditCardConfig? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CreditCardConfig.self, data: data)
    }
}
