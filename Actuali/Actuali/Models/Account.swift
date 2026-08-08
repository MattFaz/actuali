import Foundation

struct Account: Identifiable, Hashable {
    let id: String
    var name: String
    var type: AccountType
    var offBudget: Bool
    var closed: Bool
    var sortOrder: Int

    var balance: Int // Stored in cents
}

enum AccountType: String, CaseIterable {
    case checking
    case savings
    case credit
    case investment
    case mortgage
    case debt
    case other
}
