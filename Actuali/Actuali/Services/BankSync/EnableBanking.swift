import Foundation

/// A bank Enable Banking can connect to (an "ASPSP" in its API).
struct EnableBankingBank: Decodable, Sendable, Hashable, Identifiable {
    let name: String
    let country: String
    let psuTypes: [String]?
    let beta: Bool?
    /// Longest consent the bank allows, in seconds.
    let maximumConsentValidity: Int?

    var id: String {
        "\(country):\(name)"
    }

    /// Whether there is a usage type to choose; a bank that offers one only
    /// gets that one.
    var offersBothUsageTypes: Bool {
        let types = psuTypes ?? []
        return types.contains("personal") && types.contains("business")
    }

    private enum CodingKeys: String, CodingKey {
        case name, country, beta
        case psuTypes = "psu_types"
        case maximumConsentValidity = "maximum_consent_validity"
    }
}

/// Where to send the person, plus the token that identifies this attempt to `poll-auth`.
struct EnableBankingAuthorization: Sendable, Equatable {
    let url: URL
    let state: String
}

/// An account the bank released at the end of an authorization.
struct EnableBankingRemoteAccount: Decodable, Sendable, Equatable {
    let accountId: String
    let name: String
    let institution: String
    let balance: Int?

    /// Upstream's `enablebanking-accounts-link` stores the account uid as
    /// `banks.bank_id` too (one bank row per account), which is why
    /// `institutionId` is the account id.
    var remoteAccount: BankSyncRemoteAccount {
        BankSyncRemoteAccount(
            id: accountId,
            name: name,
            institutionId: accountId,
            institutionName: institution,
            balanceCents: balance,
            source: .enableBanking
        )
    }

    private enum CodingKeys: String, CodingKey {
        case name, institution, balance
        case accountId = "account_id"
    }
}

/// Which links a new authorization renews. The bank issues new account ids
/// every time, so an account that is already linked comes back looking like
/// one that is not.
enum EnableBankingLinks {
    static func sameName(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// What a new authorization of `bankName` leaves to settle: this bank's
    /// links whose account didn't come back under the id they know, and the
    /// returned accounts nothing imports from.
    static func unsettled(
        of remotes: [BankSyncRemoteAccount],
        bankName: String,
        linked: [BankSyncAccount]
    ) -> (links: [BankSyncAccount], remotes: [BankSyncRemoteAccount]) {
        let links = linked.filter {
            $0.source == .enableBanking && !$0.closed && sameName($0.institutionName, bankName)
                // An id the bank kept is a link that needs nothing done.
                && !remotes.map(\.id).contains($0.externalAccountId)
        }
        return (links, remotes.filter { $0.link(in: linked) == nil })
    }

    /// The links reauthorizing `accountId` renews, as the returned account for
    /// each budget account id. `proven` holds the pairs the transactions
    /// already settled; this adds what can be said about the rest without
    /// them, and only when the account being reauthorized is one of this
    /// bank's: picking another bank on the way is a new connection.
    ///
    /// ponytail: beyond its transactions a link stores nothing that survives
    /// a new authorization, so what they leave open is paired on what is
    /// unambiguous: a name both sides have exactly once, then (upstream's
    /// `computeInitialLinkState`) the one account still left over for the
    /// account being reauthorized. The rest is asked. Upgrade path: Enable
    /// Banking's `identification_hash`, once the server passes it through.
    static func renewals(
        of remotes: [BankSyncRemoteAccount],
        reauthorizing accountId: String,
        bankName: String,
        linked: [BankSyncAccount],
        proven: [String: BankSyncRemoteAccount] = [:]
    ) -> [String: BankSyncRemoteAccount] {
        let open = unsettled(of: remotes, bankName: bankName, linked: linked)
        guard open.links.contains(where: { $0.id == accountId }) else { return proven }
        var renewals = proven
        let stale = open.links.filter { renewals[$0.id] == nil }
        var unpaired = open.remotes.filter { remote in !renewals.values.contains { $0.id == remote.id } }

        for link in stale where stale.filter({ sameName($0.name, link.name) }).count == 1 {
            let named = unpaired.filter { sameName($0.name, link.name) }
            if named.count == 1 {
                renewals[link.id] = named[0]
            }
        }
        unpaired.removeAll { remote in renewals.values.contains { $0.id == remote.id } }
        if renewals[accountId] == nil, unpaired.count == 1 {
            renewals[accountId] = unpaired[0]
        }
        return renewals
    }
}

enum EnableBankingAuthError: LocalizedError, Equatable {
    case timedOut
    case failed(String)
    case insecureServer
    /// The server reached Enable Banking but got no bank list back; carries
    /// Enable Banking's own reason.
    case bankListFailed(String)

    var errorDescription: String? {
        switch self {
        case .bankListFailed(let reason):
            String(format: String(localized: "The bank list couldn't be loaded: %@"), reason)
        case .timedOut:
            String(localized: "Your bank didn't confirm in time. Try again.")
        case .failed(let reason):
            String(format: String(localized: "Bank authorization failed: %@"), reason)
        case .insecureServer:
            String(localized: "Enable Banking needs your Actual server to use https.")
        }
    }
}
