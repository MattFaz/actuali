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

    private static func formatISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: string)
    }

    enum CodingKeys: String, CodingKey {
        case statementDay
        case dueOffsetDays
        case limit
        case updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statementDay = try container.decode(Int.self, forKey: .statementDay)
        dueOffsetDays = try container.decodeIfPresent(Int.self, forKey: .dueOffsetDays) ?? CreditCardCycle.defaultDueOffsetDays
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)

        if let dateString = try container.decodeIfPresent(String.self, forKey: .updatedAt) {
            updatedAt = Self.parseISO8601(dateString) ?? Date()
        } else {
            updatedAt = Date()
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(statementDay, forKey: .statementDay)
        try container.encode(dueOffsetDays, forKey: .dueOffsetDays)
        try container.encodeIfPresent(limit, forKey: .limit)
        try container.encode(Self.formatISO8601(updatedAt), forKey: .updatedAt)
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
