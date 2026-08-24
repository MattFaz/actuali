import Foundation

/// The provider an account's transactions are downloaded from. Actual stores
/// this in `accounts.account_sync_source`; Actuali only speaks SimpleFIN, but
/// the column is shared with every other client, so a value it doesn't
/// recognise has to survive a round trip untouched.
enum BankSyncSource: String, Sendable, Equatable {
    case simpleFin = "simpleFin"
}

/// An account wired up to a bank feed: the budget's account plus the
/// provider-side id its transactions come from.
struct BankSyncAccount: Sendable, Equatable, Identifiable {
    /// The budget's account id.
    let id: String
    let name: String
    /// `accounts.account_id` — the id the provider knows the account by.
    let externalAccountId: String
    /// `accounts.account_sync_source`, verbatim. Not every value maps to a
    /// provider Actuali can sync (see `source`).
    let syncSource: String
    let offBudget: Bool
    let closed: Bool

    var source: BankSyncSource? { BankSyncSource(rawValue: syncSource) }
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
