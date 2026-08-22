import Foundation

/// One account to download, and how far back to reach for it.
struct BankSyncTarget: Sendable, Equatable {
    /// The provider's account id (`accounts.account_id`).
    let externalId: String
    /// Earliest day (`YYYYMMDD`) worth downloading for this account.
    let startDay: Int
}

/// What a provider came back with for one account.
struct BankSyncDownload: Sendable, Equatable {
    var candidates: [BankSyncCandidate] = []
    /// The account's balance as of now, for working out an opening balance on
    /// a first sync.
    var currentBalanceCents: Int?
    /// Something the person should know about this account, if anything.
    var problem: String?
    /// Actual's `bank_sync_status` value for this account after the download,
    /// so the web UI reads the same state this device saw.
    var status: String = "ok"
}

struct BankSyncDownloadSet: Sendable, Equatable {
    var byAccount: [String: BankSyncDownload] = [:]
    /// Problems that aren't tied to a single account.
    var problems: [String] = []
}

/// Where a bank download comes from.
///
/// Two of these exist because the credential can live in either of two places
/// and they can't be shared: Actual keeps the server's SimpleFIN access key in
/// its own secrets store, deliberately out of the budget file, so no amount of
/// syncing will hand it to this device. Preferring the server when it has one
/// (see `BudgetStore.makeBankSyncProvider`) means a person who set SimpleFIN
/// up on the web doesn't have to claim a second setup token here, and a person
/// who links an account here doesn't leave the web with a link it can't
/// service. The device's own key is the fallback for servers that have no
/// SimpleFIN of their own.
protocol BankSyncProvider: Sendable {
    /// Every account the connection covers, for the linking screen.
    func accounts() async throws -> [SimpleFINAccount]
    func download(_ targets: [BankSyncTarget]) async throws -> BankSyncDownloadSet
}

// MARK: - The device's own connection

/// Talks to the SimpleFIN bridge directly with a key this device claimed.
struct SimpleFINDirectProvider: BankSyncProvider {
    let client: SimpleFINClient
    let accessKey: SimpleFINAccessKey

    func accounts() async throws -> [SimpleFINAccount] {
        try await client.fetchAccounts(accessKey: accessKey).accounts
    }

    func download(_ targets: [BankSyncTarget]) async throws -> BankSyncDownloadSet {
        guard let earliest = targets.map(\.startDay).min() else { return BankSyncDownloadSet() }

        // One request covers every account, so it reaches back as far as the
        // hungriest of them; each account drops the surplus below.
        let downloaded = try await client.fetchAccounts(
            accessKey: accessKey,
            accountIds: targets.map(\.externalId),
            startDate: earliest
        )

        var set = BankSyncDownloadSet()
        for target in targets {
            guard let remote = downloaded.accounts.first(where: { $0.id == target.externalId })
            else { continue }

            var download = BankSyncDownload(
                candidates: remote.transactions
                    .compactMap(BankSyncCandidate.init(simpleFIN:))
                    .filter { $0.date >= target.startDay },
                currentBalanceCents: remote.balanceCents
            )
            // The bridge's errors aren't keyed by account, so pair them up the
            // way upstream's server does — by the institution they name.
            if let attention = downloaded.errors.first(where: {
                $0.hasPrefix("Connection to \(remote.org.displayName) may need attention")
            }) {
                download.problem = attention
                download.status = "attention-required"
            }
            set.byAccount[target.externalId] = download
        }

        // Anything left over is about the connection, not one account.
        let named = Set(
            downloaded.accounts
                .filter { account in targets.contains { $0.externalId == account.id } }
                .map { "Connection to \($0.org.displayName) may need attention" }
        )
        set.problems = downloaded.errors.filter { error in
            !named.contains { error.hasPrefix($0) }
        }
        return set
    }
}

// MARK: - The server's connection

/// Routes the download through the Actual server's own SimpleFIN credentials,
/// which it already exposes to any authenticated client at `/simplefin/*`.
struct ActualServerBankSyncProvider: BankSyncProvider {
    let client: ActualServerClient

    func accounts() async throws -> [SimpleFINAccount] {
        try await client.simpleFINAccounts()
    }

    func download(_ targets: [BankSyncTarget]) async throws -> BankSyncDownloadSet {
        guard !targets.isEmpty else { return BankSyncDownloadSet() }

        let downloaded = try await client.simpleFINTransactions(
            accountIds: targets.map(\.externalId),
            startDates: targets.map { BankSyncReconciler.isoString(from: $0.startDay) }
        )

        var set = BankSyncDownloadSet()
        if let failure = downloaded.failure {
            // The whole request was rejected, so no account got as far as
            // having its own problem.
            set.problems.append(
                failure.reason ?? "Your server's SimpleFIN connection was rejected."
            )
            return set
        }

        for target in targets {
            let account = downloaded.accounts[target.externalId]
            let error = downloaded.errors[target.externalId]?.first
            // Neither data nor an error means the server didn't mention this
            // account at all; leave the key out so the caller says so.
            guard account != nil || error != nil else { continue }

            var download = BankSyncDownload()
            if let error {
                download.problem = error.reason ?? error.errorCode
                download.status = error.bankSyncStatus
            }
            if let account {
                download.candidates = (account.transactions?.all ?? [])
                    .compactMap(BankSyncCandidate.init(serverBankSync:))
                    .filter { $0.date >= target.startDay }
                download.currentBalanceCents = account.startingBalance
            }
            set.byAccount[target.externalId] = download
        }
        return set
    }
}
