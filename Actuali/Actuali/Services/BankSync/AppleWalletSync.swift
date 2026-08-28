import Foundation

/// Whether this device can serve Wallet (FinanceKit) data, and whether the
/// person has let Actuali read it.
enum AppleWalletAvailability: Sendable, Equatable {
    /// No FinanceKit data on this device — Apple Card, Apple Cash and
    /// Savings are iPhone-only and currently US-only.
    case unsupported
    case notDetermined
    case denied
    case authorized
}

/// A Wallet account (Apple Card, Apple Cash, Savings), reduced to what
/// linking and syncing need. Framework-free so everything above the thin
/// FinanceKit bridge stays unit-testable — the same seam as
/// `WalletImportMapper` (GH #55, Tier 1); this is the Tier-2 automatic sync.
struct AppleWalletAccount: Identifiable, Sendable, Equatable {
    /// FinanceKit account UUID, lowercased — stored as `accounts.account_id`.
    let id: String
    let name: String
    /// What FinanceKit reports for the issuing institution ("Apple").
    let institutionName: String
    /// Signed like `Transaction.amount`: money owed is negative, so an Apple
    /// Card balance imports the way a credit card's should.
    let balanceCents: Int?
}

/// A Wallet transaction as the bridge hands it over — raw enough that the
/// normalization into a `BankSyncCandidate` stays testable off-device.
struct AppleWalletTransaction: Sendable, Equatable {
    /// FinanceKit transaction UUID, lowercased. The Tier-1 picker import
    /// stores the same form as `financial_id`, so a transaction someone
    /// hand-picked earlier is recognised rather than imported twice.
    let id: String
    /// Unsigned; `isCredit` carries the direction.
    let amount: Decimal
    let isCredit: Bool
    let merchantName: String?
    let description: String
    let status: WalletImportMapper.Status
    let date: Date
}

/// The slice of FinanceKit the sync needs. A protocol because the real store
/// only answers on entitled devices — tests stub it.
protocol AppleWalletReading: Sendable {
    func availability() async -> AppleWalletAvailability
    /// Ask the person for read access. Returns whether it was granted.
    func requestAccess() async throws -> Bool
    func accounts() async throws -> [AppleWalletAccount]
    func transactions(accountId: String) async throws -> [AppleWalletTransaction]
}

/// Turns Wallet data into the same download shape the SimpleFIN providers
/// produce, so one import path (`BudgetStore.importBankSync`) serves both.
struct AppleWalletProvider: Sendable {
    let store: any AppleWalletReading

    func download(_ targets: [BankSyncTarget]) async throws -> BankSyncDownloadSet {
        let accounts = try await store.accounts()

        var set = BankSyncDownloadSet()
        for target in targets {
            // An account this Wallet doesn't have is left out so the caller
            // says so — usually a link made from another device's Wallet.
            guard let account = accounts.first(where: { $0.id == target.externalId })
            else { continue }

            let transactions = try await store.transactions(accountId: target.externalId)
            set.byAccount[target.externalId] = BankSyncDownload(
                candidates: transactions
                    .compactMap(BankSyncCandidate.init(appleWallet:))
                    .filter { $0.date >= target.startDay },
                currentBalanceCents: account.balanceCents
            )
        }
        return set
    }
}

extension AppleWalletAccount {
    /// FinanceKit has no institution id of its own, so the name doubles as
    /// `banks.bank_id` — the same fallback SimpleFIN orgs without one use.
    var remoteAccount: BankSyncRemoteAccount {
        BankSyncRemoteAccount(
            id: id,
            name: name,
            institutionId: institutionName,
            institutionName: institutionName,
            balanceCents: balanceCents,
            source: .financeKit
        )
    }
}
