import Foundation

/// A transaction extracted from a shared bank message, queued for user review
/// before being logged to the budget. Lives in a lightweight JSON file, not
/// the CRDT database — these aren't real transactions until approved.
struct PendingImport: Codable, Identifiable {
    let id: UUID
    let originBudgetId: String?
    var amount: Double?
    var sourceCurrencyCode: String?
    var payee: String?
    var cardHint: String?
    var date: Date
    var isIncome: Bool
    var rawText: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        originBudgetId: String? = nil,
        amount: Double? = nil,
        sourceCurrencyCode: String? = nil,
        payee: String? = nil,
        cardHint: String? = nil,
        date: Date = Date(),
        isIncome: Bool = false,
        rawText: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.originBudgetId = originBudgetId
        self.amount = amount
        self.sourceCurrencyCode = sourceCurrencyCode
        self.payee = payee
        self.cardHint = cardHint
        self.date = date
        self.isIncome = isIncome
        self.rawText = rawText
        self.createdAt = createdAt
    }

    nonisolated static func normalizedCurrencyCode(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

enum PendingImportReviewRequirement: Hashable {
    case adoptIntoActiveBudget
    case confirmActiveBudgetCurrency(source: String?, budget: String)

    var prompt: String {
        switch self {
        case .adoptIntoActiveBudget:
            return String(localized: "I confirm that this import should be adopted into the active budget.")
        case let .confirmActiveBudgetCurrency(source, budget):
            if let source {
                return String(localized: "I confirm that the numeric amount is in the active budget currency (\(budget)); no conversion from \(source) will be performed.")
            }
            return String(localized: "I confirm that the numeric amount should be treated as the active budget currency (\(budget)); no conversion will be performed.")
        }
    }
}

extension PendingImport {
    nonisolated func reviewRequirements(
        activeBudgetId: String?,
        budgetCurrency: String
    ) -> [PendingImportReviewRequirement] {
        var requirements: [PendingImportReviewRequirement] = []
        if originBudgetId == nil || originBudgetId != activeBudgetId {
            requirements.append(.adoptIntoActiveBudget)
        }

        let normalizedBudget = Self.normalizedCurrencyCode(budgetCurrency)
        guard let sourceCurrencyCode else {
            requirements.append(.confirmActiveBudgetCurrency(source: nil, budget: normalizedBudget))
            return requirements
        }
        let normalizedSource = Self.normalizedCurrencyCode(sourceCurrencyCode)
        if normalizedSource != normalizedBudget {
            requirements.append(.confirmActiveBudgetCurrency(source: normalizedSource, budget: normalizedBudget))
        }
        return requirements
    }
}
