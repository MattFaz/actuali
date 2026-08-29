import Foundation

/// Synced configuration for a credit card account, persisted in Actual's `preferences` table.
/// Stored under the key `actuali:credit_card:<accountId>` as a JSON string.
struct CreditCardConfig: Codable, Equatable, Hashable, Sendable {
    var statementDay: Int
    var dueOffsetDays: Int = CreditCardCycle.defaultDueOffsetDays
    var limit: Int?
}

extension CreditCardConfig {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statementDay = try container.decode(Int.self, forKey: .statementDay)
        dueOffsetDays = try container.decodeIfPresent(Int.self, forKey: .dueOffsetDays) ?? CreditCardCycle.defaultDueOffsetDays
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)
    }
}
