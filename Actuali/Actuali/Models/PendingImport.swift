import Foundation

/// A transaction extracted from a shared bank message, queued for user review
/// before being logged to the budget. Lives in a lightweight JSON file, not
/// the CRDT database — these aren't real transactions until approved.
struct PendingImport: Codable, Identifiable {
    let id: UUID
    var amount: Double?
    var payee: String?
    var cardHint: String?
    var date: Date
    var isIncome: Bool
    var rawText: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        amount: Double? = nil,
        payee: String? = nil,
        cardHint: String? = nil,
        date: Date = Date(),
        isIncome: Bool = false,
        rawText: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.amount = amount
        self.payee = payee
        self.cardHint = cardHint
        self.date = date
        self.isIncome = isIncome
        self.rawText = rawText
        self.createdAt = createdAt
    }
}
