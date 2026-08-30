import Foundation

/// The provider an account's transactions are downloaded from. Synced links
/// use `accounts.account_sync_source`; FinanceKit links stay device-local.
enum BankSyncSource: String, Sendable, Equatable {
    case simpleFin = "simpleFin"
    /// Apple Card / Apple Cash / Savings via FinanceKit. Ours alone because
    /// the identifiers and data only exist in this device's Wallet.
    case financeKit = "financeKit"
}

/// An account wired up to a bank feed: the budget's account plus the
/// provider-side id its transactions come from.
struct BankSyncAccount: Sendable, Equatable, Identifiable {
    /// The budget's account id.
    let id: String
    let name: String
    /// The id the provider knows the account by. FinanceKit keeps it locally;
    /// other providers read it from `accounts.account_id`.
    let externalAccountId: String
    /// The provider name. Database-backed links preserve
    /// `accounts.account_sync_source` verbatim; FinanceKit supplies it locally.
    let syncSource: String
    let offBudget: Bool
    let closed: Bool

    var source: BankSyncSource? { BankSyncSource(rawValue: syncSource) }
}

/// A provider-side account offered for linking, whichever provider it came
/// from — what the link flow needs and nothing more.
struct BankSyncRemoteAccount: Identifiable, Sendable, Equatable {
    /// The provider's account id.
    let id: String
    let name: String
    /// The provider's institution id.
    let institutionId: String
    let institutionName: String
    let balanceCents: Int?
    let source: BankSyncSource
}

extension SimpleFINAccount {
    var remoteAccount: BankSyncRemoteAccount {
        BankSyncRemoteAccount(
            id: id,
            name: name,
            institutionId: org.bankId ?? org.displayName,
            institutionName: org.displayName,
            balanceCents: balanceCents,
            source: .simpleFin
        )
    }
}

/// Actual's `banks` row: the institution behind one or more linked accounts.
/// Written so an account linked here looks the same to the web UI as one
/// linked there — its unlink path reads `accounts.bank` and does nothing
/// without it.
struct Bank: Identifiable, Hashable, Sendable {
    let id: String
    /// The provider's own institution id — SimpleFIN's org domain, falling
    /// back to its org id.
    var bankId: String
    var name: String
    var tombstone: Bool = false
}

extension Bank: CRDTSyncable {
    static var datasetName: String { "banks" }

    var syncableFields: [String: Any?] {
        [
            "bank_id": bankId,
            "name": name,
            "tombstone": tombstone ? 1 : 0
        ]
    }
}
