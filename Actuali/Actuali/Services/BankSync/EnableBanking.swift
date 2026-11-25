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

    private enum CodingKeys: String, CodingKey {
        case name, country, beta
        case psuTypes = "psu_types"
        case maximumConsentValidity = "maximum_consent_validity"
    }
}

/// Where to send the person, plus the token that identifies this attempt to `poll-auth`.
struct EnableBankingAuthorization: Decodable, Sendable, Equatable {
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

enum EnableBankingAuthError: LocalizedError, Equatable {
    case timedOut
    case failed(String)
    case insecureServer

    var errorDescription: String? {
        switch self {
        case .timedOut:
            String(localized: "Your bank didn't confirm in time. Try again.")
        case .failed(let reason):
            String(format: String(localized: "Bank authorization failed: %@"), reason)
        case .insecureServer:
            String(localized: "Enable Banking needs your Actual server to use https.")
        }
    }
}
