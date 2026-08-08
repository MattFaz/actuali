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

/// Cleared / uncleared / reconciled totals for one account (GH #134).
/// Reconciled rows are a subset of cleared, so cleared + uncleared is the
/// account balance while reconciled is informational.
struct AccountBalanceBreakdown: Equatable {
    let cleared: Int // Stored in cents, like Account.balance
    let uncleared: Int
    let reconciled: Int
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
