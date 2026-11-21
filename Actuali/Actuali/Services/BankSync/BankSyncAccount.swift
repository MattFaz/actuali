import Foundation

/// The provider an account's transactions are downloaded from. Synced links
/// use `accounts.account_sync_source`; FinanceKit links stay device-local.
enum BankSyncSource: String, Sendable, Equatable {
    case simpleFin
    /// Apple Card / Apple Cash / Savings via FinanceKit. Ours alone because
    /// the identifiers and data only exist in this device's Wallet.
    case financeKit
}

struct ExpectedBankSyncLink: Sendable, Equatable {
    let accountId: String
    let externalAccountId: String
    let source: String
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
    /// When a download last completed (`accounts.last_sync`); nil if none has.
    var lastSync: Date?
    /// How the latest attempt ended (`accounts.bank_sync_status`): `ok`, or
    /// one of upstream's failure words.
    var status: String?

    var source: BankSyncSource? {
        BankSyncSource(rawValue: syncSource)
    }

    /// Whether the latest attempt ended in anything but a clean download.
    var needsAttention: Bool {
        status != nil && status != "ok"
    }

    /// What went wrong on the latest attempt and what to do about it, in
    /// upstream's `bank_sync_status` vocabulary. Nil after a clean download.
    var attentionMessage: String? {
        switch status {
        case nil, "ok": nil
        case "reauth-required": String(localized: "Your bank needs you to sign in again at SimpleFIN.")
        case "attention-required": String(localized: "Your bank connection needs attention at SimpleFIN.")
        case "rate-limit-exceeded": String(localized: "Too many sync requests today. Try again tomorrow.")
        case "timed-out": String(localized: "The bank took too long to answer. Try again later.")
        case "account-missing": String(localized: "The bank feed no longer has this account. Unlink it and link it again.")
        default: String(localized: "The last bank sync failed. Try again later.")
        }
    }
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
    static var datasetName: String {
        "banks"
    }

    var syncableFields: [String: Any?] {
        [
            "bank_id": bankId,
            "name": name,
            "tombstone": tombstone ? 1 : 0,
        ]
    }
}

/// A downloaded transaction held back for approval instead of imported.
/// Kept as the provider sent it, so approving runs it through the same
/// matching and rules as an ordinary sync.
struct StagedBankTransaction: Codable, Identifiable, Equatable, Sendable {
    var accountId: String
    var importedId: String
    var date: Int // YYYYMMDD
    var amount: Int // cents, negative = outflow
    var payeeName: String
    var notes: String?
    var cleared: Bool
    /// How many identical rows the bank sent under this id. Rare, but a feed
    /// can list the same charge twice and both are real.
    var occurrences = 1

    var id: String {
        "\(accountId)|\(importedId)"
    }

    init(accountId: String, candidate: BankSyncCandidate, occurrences: Int = 1) {
        self.accountId = accountId
        importedId = candidate.importedId
        date = candidate.date
        amount = candidate.amount
        payeeName = candidate.payeeName
        notes = candidate.notes
        cleared = candidate.cleared
        self.occurrences = occurrences
    }

    var candidate: BankSyncCandidate {
        BankSyncCandidate(
            importedId: importedId, date: date, amount: amount,
            payeeName: payeeName, notes: notes, cleared: cleared
        )
    }
}
