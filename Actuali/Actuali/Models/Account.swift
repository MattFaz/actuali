import Foundation

struct Account: Identifiable, Hashable {
    let id: String
    var name: String
    var type: AccountType
    var offBudget: Bool
    var closed: Bool
    var sortOrder: Int
    var groupId: String?

    var balance: Int // Stored in cents
}

struct AccountGroup: Identifiable, Hashable {
    let id: String
    var name: String
    var sortOrder: Double
    var tombstone: Bool = false
}

extension AccountGroup: CRDTSyncable {
    static var datasetName: String {
        "account_groups"
    }

    var syncableFields: [String: Any?] {
        ["name": name, "sort_order": sortOrder, "tombstone": tombstone ? 1 : 0]
    }
}

/// Cleared / uncleared / reconciled totals for one account (GH #134).
/// Reconciled rows are a subset of cleared, so cleared + uncleared is the
/// account balance while reconciled is informational.
struct AccountBalanceBreakdown: Equatable {
    let cleared: Int // Stored in cents, like Account.balance
    let uncleared: Int
    let reconciled: Int
}

/// Account kinds, stored as plain strings in Actual's nullable `accounts.type`
/// column. Actual's own app never reads or shows that column, so only Actuali
/// and Actua (which write these same seven values) use it. A missing or
/// unknown value reads as checking, as in Actua.
enum AccountType: String, CaseIterable {
    case checking
    case savings
    case credit
    case investment
    case mortgage
    case debt
    case other

    var title: String {
        switch self {
        case .checking: String(localized: "accounts.type.checking")
        case .savings: String(localized: "accounts.type.savings")
        case .credit: String(localized: "accounts.type.credit")
        case .investment: String(localized: "accounts.type.investment")
        case .mortgage: String(localized: "accounts.type.mortgage")
        case .debt: String(localized: "accounts.type.debt")
        case .other: String(localized: "accounts.type.other")
        }
    }
}

// MARK: - CRDTSyncable

extension Account: CRDTSyncable {
    static var datasetName: String {
        "accounts"
    }

    /// Only the fields a manually-created (non-bank-linked) account sets.
    /// Bank-sync columns (account_id, balance_current, mask, official_name,
    /// subtype, bank) stay untouched — matching how the PWA leaves them null
    /// for a local account, same as `financial_id` on Transaction.
    var syncableFields: [String: Any?] {
        [
            "name": name,
            "type": type.rawValue,
            "offbudget": offBudget ? 1 : 0,
            "closed": closed ? 1 : 0,
            "tombstone": 0,
            "sort_order": sortOrder,
        ]
    }
}
