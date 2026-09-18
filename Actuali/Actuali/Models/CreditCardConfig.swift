import Foundation

/// Synced configuration for a credit card account, persisted in Actual's `preferences` table.
/// Stored under the key `actuali:credit_card:<accountId>` as a JSON string.
struct CreditCardConfig: Codable, Equatable, Hashable, Sendable {
    var statementDay: Int
    var dueOffsetDays: Int = CreditCardCycle.defaultDueOffsetDays
    var dueDay: Int? = nil
    var limit: Int? = nil
}

extension CreditCardConfig {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.statementDay = try container.decode(Int.self, forKey: .statementDay)
        self.dueOffsetDays = try container.decodeIfPresent(Int.self, forKey: .dueOffsetDays) ?? CreditCardCycle.defaultDueOffsetDays
        self.dueDay = try container.decodeIfPresent(Int.self, forKey: .dueDay)
        if let dueDay, !(1 ... 31).contains(dueDay) {
            throw DecodingError.dataCorruptedError(forKey: .dueDay, in: container, debugDescription: "dueDay must be between 1 and 31")
        }
        self.limit = try container.decodeIfPresent(Int.self, forKey: .limit)
    }

    var paymentDue: CreditCardCycle.PaymentDue {
        if let dueDay {
            return .dayOfMonth(dueDay)
        }
        return .daysAfter(dueOffsetDays)
    }
}
