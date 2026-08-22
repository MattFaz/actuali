import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "SimpleFIN")

// MARK: - Errors

enum SimpleFINError: LocalizedError, Equatable {
    /// The pasted setup token isn't base64, or doesn't decode to an https URL.
    case invalidSetupToken
    /// The stored access key isn't in `scheme://user:pass@host/path` form.
    case invalidAccessKey
    /// The bridge refused the claim — setup tokens are single-use, so this
    /// usually means the token was already claimed (by another app or an
    /// earlier attempt).
    case claimRejected
    /// Basic auth was rejected: the access key is no longer valid.
    case forbidden
    case httpError(statusCode: Int)
    case invalidResponse
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidSetupToken:
            return "That doesn't look like a SimpleFIN setup token. Copy the whole token from SimpleFIN and paste it again."
        case .invalidAccessKey:
            return "The stored SimpleFIN access key is unreadable. Disconnect SimpleFIN and set it up again."
        case .claimRejected:
            return "SimpleFIN rejected this setup token. Tokens can only be claimed once — generate a new one at SimpleFIN and paste that."
        case .forbidden:
            return "SimpleFIN rejected the saved access key. Disconnect SimpleFIN and set it up again with a new setup token."
        case .httpError(let statusCode):
            return "SimpleFIN returned an unexpected response (HTTP \(statusCode))."
        case .invalidResponse:
            return "SimpleFIN returned a response Actuali couldn't read."
        case .networkError(let message):
            return "Couldn't reach SimpleFIN: \(message)"
        }
    }
}

// MARK: - Access key

/// The long-lived credential a claimed setup token yields, in SimpleFIN's
/// `https://user:password@bridge.example.com/simplefin` form.
///
/// Parsed by hand rather than through `URLComponents`: the bridge's generated
/// passwords are arbitrary strings, and `URLComponents` refuses (or silently
/// mangles) several characters that appear in them.
struct SimpleFINAccessKey: Sendable, Equatable {
    /// The key exactly as SimpleFIN issued it. Kept so it can be stored and
    /// read back byte for byte rather than reassembled from its parts.
    let raw: String
    let baseURL: URL
    let username: String
    let password: String

    /// The `Authorization` header value every request carries.
    var basicAuthHeader: String? {
        guard let data = "\(username):\(password)".data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    static func parse(_ raw: String) throws -> SimpleFINAccessKey {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeRange = trimmed.range(of: "://") else {
            throw SimpleFINError.invalidAccessKey
        }
        let scheme = String(trimmed[trimmed.startIndex..<schemeRange.lowerBound])
        let rest = String(trimmed[schemeRange.upperBound...])

        // Split on the *last* "@": the password may legitimately contain one,
        // the host may not.
        guard let atIndex = rest.lastIndex(of: "@") else {
            throw SimpleFINError.invalidAccessKey
        }
        let auth = String(rest[rest.startIndex..<atIndex])
        let host = String(rest[rest.index(after: atIndex)...])

        // Split on the *first* ":" for the same reason, in reverse.
        guard let colonIndex = auth.firstIndex(of: ":") else {
            throw SimpleFINError.invalidAccessKey
        }
        let username = String(auth[auth.startIndex..<colonIndex])
        let password = String(auth[auth.index(after: colonIndex)...])

        // iOS blocks cleartext HTTP outright (App Transport Security), and the
        // key travels in an Authorization header, so refuse anything but https
        // here rather than failing later with a confusing transport error.
        guard scheme.lowercased() == "https", !host.isEmpty,
              !username.isEmpty, !password.isEmpty,
              let baseURL = URL(string: "https://\(host)") else {
            throw SimpleFINError.invalidAccessKey
        }

        return SimpleFINAccessKey(
            raw: trimmed, baseURL: baseURL, username: username, password: password
        )
    }

    /// The claim URL a setup token encodes. Setup tokens are the base64 of a
    /// plain URL — nothing more.
    static func claimURL(fromSetupToken token: String) throws -> URL {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]),
              let decoded = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: decoded),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            throw SimpleFINError.invalidSetupToken
        }
        return url
    }
}

// MARK: - Protocol types

/// A `GET /accounts` response. `errors` carries bridge-level problems (a
/// connection that needs re-authenticating, say) alongside whatever account
/// data did come back, so it is never a reason to discard the accounts.
struct SimpleFINAccountSet: Decodable, Sendable, Equatable {
    var errors: [String]
    var accounts: [SimpleFINAccount]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Bridges have been seen sending structured errors here rather than
        // the protocol's array of strings; an unreadable `errors` must not
        // cost us the account data alongside it.
        if let decoded = try? container.decodeIfPresent([String].self, forKey: .errors) {
            errors = decoded
        } else {
            errors = []
        }
        accounts = try container.decodeIfPresent([SimpleFINAccount].self, forKey: .accounts) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case errors, accounts
    }
}

struct SimpleFINOrg: Decodable, Sendable, Equatable {
    let domain: String?
    let name: String?
    let id: String?

    /// The stable identifier Actual keys its `banks` rows on
    /// (`orgDomain ?? orgId` upstream), so an account linked here and an
    /// account linked in the web UI land on the same bank row.
    var bankId: String? { domain ?? id }

    /// What to show a person picking accounts. Falls back through the org's
    /// other identifiers rather than showing nothing.
    var displayName: String { name ?? domain ?? id ?? "Unknown institution" }

    private enum CodingKeys: String, CodingKey {
        case domain, name, id
    }
}

struct SimpleFINAccount: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let org: SimpleFINOrg
    /// Decimal string, e.g. "-1234.56". Use `balanceCents`.
    let balance: String
    let availableBalance: String?
    /// Seconds since the epoch.
    let balanceDate: Int?
    let transactions: [SimpleFINTransaction]

    var balanceCents: Int? { SimpleFINAmount.cents(from: balance) }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Account"
        org = try container.decode(SimpleFINOrg.self, forKey: .org)
        balance = try container.decodeIfPresent(String.self, forKey: .balance) ?? "0"
        availableBalance = try container.decodeIfPresent(String.self, forKey: .availableBalance)
        balanceDate = try container.decodeIfPresent(Int.self, forKey: .balanceDate)
        // Absent entirely on a `balances-only` fetch.
        transactions = try container.decodeIfPresent([SimpleFINTransaction].self, forKey: .transactions) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, org, balance, transactions
        case availableBalance = "available-balance"
        case balanceDate = "balance-date"
    }
}

struct SimpleFINTransaction: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    /// Seconds since the epoch; 0 while the transaction is still pending.
    let posted: Int
    /// Seconds since the epoch, when the bank reports it.
    let transactedAt: Int?
    /// Decimal string, e.g. "-33.45". Use `amountCents`.
    let amount: String
    let description: String?
    let payee: String?
    let memo: String?
    let pending: Bool?

    var amountCents: Int? { SimpleFINAmount.cents(from: amount) }

    /// Whether the bank considers the transaction final. Mirrors upstream's
    /// `trans.pending ?? trans.posted === 0` — `pending` is optional in the
    /// protocol, and a zero `posted` is how bridges that omit it say the same
    /// thing. Booked transactions import as cleared.
    var isBooked: Bool { !(pending ?? (posted == 0)) }

    /// The timestamp the transaction's date comes from: what the bank posted
    /// it on once it is final, when it happened while it is still pending.
    var effectiveTimestamp: Int { isBooked ? posted : (transactedAt ?? posted) }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        posted = try container.decodeIfPresent(Int.self, forKey: .posted) ?? 0
        transactedAt = try container.decodeIfPresent(Int.self, forKey: .transactedAt)
        amount = try container.decodeIfPresent(String.self, forKey: .amount) ?? "0"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        payee = try container.decodeIfPresent(String.self, forKey: .payee)
        memo = try container.decodeIfPresent(String.self, forKey: .memo)
        pending = try container.decodeIfPresent(Bool.self, forKey: .pending)
    }

    private enum CodingKeys: String, CodingKey {
        case id, posted, amount, description, payee, memo, pending
        case transactedAt = "transacted_at"
    }
}

// MARK: - Amounts and dates

/// SimpleFIN sends money as decimal strings ("-33.45") and times as UNIX
/// seconds, neither of which any existing helper here reads.
enum SimpleFINAmount {
    /// Integer cents for a SimpleFIN decimal string, or nil if it isn't one.
    ///
    /// Parsed through `Decimal` rather than `Double` so amounts round-trip
    /// exactly, and with an explicit shape check first because
    /// `Decimal(string:)` happily reads a leading number out of any junk.
    static func cents(from raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDecimalString(trimmed) else { return nil }
        // Decimal(string:) doesn't read an explicit "+", which the shape check
        // above allows because the protocol does.
        let unsigned = trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed
        guard let value = Decimal(string: unsigned, locale: posixLocale) else { return nil }

        var scaled = value * 100
        var rounded = Decimal()
        // .plain rounds halves away from zero, matching Transaction.cents.
        NSDecimalRound(&rounded, &scaled, 0, .plain)

        guard rounded >= Decimal(Int.min), rounded <= Decimal(Int.max) else { return nil }
        return NSDecimalNumber(decimal: rounded).intValue
    }

    /// `YYYYMMDD` for a UNIX timestamp, in UTC.
    ///
    /// UTC, not the device's zone: upstream's server takes the date off an ISO
    /// string (`toISOString().split('T')[0]`), so a transaction imported here
    /// and the same one imported by the web UI land on the same day instead of
    /// drifting apart by one for anyone east or west of Greenwich.
    static func day(fromTimestamp timestamp: Int) -> Int {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let parts = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    /// The UNIX timestamp for midnight UTC on a `YYYYMMDD` day — what the
    /// `start-date` query parameter takes.
    static func timestamp(fromDay day: Int) -> Int {
        var components = DateComponents()
        components.year = day / 10000
        components.month = (day % 10000) / 100
        components.day = day % 100
        guard let date = utcCalendar.date(from: components) else { return 0 }
        return Int(date.timeIntervalSince1970)
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    private static func isDecimalString(_ value: String) -> Bool {
        var digitsSeen = false
        var dotSeen = false
        for (offset, character) in value.enumerated() {
            switch character {
            case "+", "-":
                guard offset == 0 else { return false }
            case ".":
                guard !dotSeen else { return false }
                dotSeen = true
            case "0"..."9":
                digitsSeen = true
            default:
                return false
            }
        }
        return digitsSeen
    }
}

// MARK: - Client

/// Talks the SimpleFIN protocol (https://www.simplefin.org/protocol.html)
/// straight from the device: claim a setup token once, then `GET /accounts`
/// with the resulting access key on every sync.
///
/// Actual's own SimpleFIN support runs through its sync server, which holds
/// the access key and proxies the bridge. Actuali claims its own key instead,
/// so bank sync works against any server (including ones the user doesn't
/// administer) — the two coexist because both write the bridge's transaction
/// id into `financial_id`, so whichever imports a transaction first, the other
/// recognises it as already imported.
actor SimpleFINClient {
    private let session: URLSession

    /// - Parameter session: overridable so tests can drive the client through a
    ///   stub transport; production callers take the default.
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        // A first sync can pull 90 days across every linked account.
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    /// Exchange a setup token for the long-lived access key. Setup tokens are
    /// single-use: a second claim of the same token fails.
    func claimAccessKey(setupToken: String) async throws -> SimpleFINAccessKey {
        let claimURL = try SimpleFINAccessKey.claimURL(fromSetupToken: setupToken)

        var request = URLRequest(url: claimURL)
        request.httpMethod = "POST"

        let (data, response) = try await send(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimpleFINError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            logger.error("SimpleFIN claim failed (HTTP \(httpResponse.statusCode, privacy: .public))")
            throw httpResponse.statusCode == 403 ? SimpleFINError.claimRejected
                                                 : SimpleFINError.httpError(statusCode: httpResponse.statusCode)
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw SimpleFINError.invalidResponse
        }
        // The bridge answers 200 with a "Forbidden…" body for an already-claimed
        // token, so the status code alone doesn't settle it.
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Forbidden") else {
            throw SimpleFINError.claimRejected
        }
        do {
            return try SimpleFINAccessKey.parse(body)
        } catch {
            // A bridge that answers 200 with something that isn't an access key
            // is telling us the token was no good, not that our parser is.
            throw SimpleFINError.claimRejected
        }
    }

    /// Balances (and optionally transactions) for the accounts the access key
    /// covers.
    /// - Parameters:
    ///   - accountIds: restricts the fetch to these bridge account ids; empty
    ///     fetches everything, which is what the account picker wants.
    ///   - startDate: earliest day (`YYYYMMDD`) to pull transactions from.
    ///     `nil` asks for balances only, skipping the bridge's transaction work.
    func fetchAccounts(
        accessKey: SimpleFINAccessKey,
        accountIds: [String] = [],
        startDate: Int? = nil
    ) async throws -> SimpleFINAccountSet {
        guard var components = URLComponents(
            url: accessKey.baseURL.appendingPathComponent("accounts"),
            resolvingAgainstBaseURL: false
        ) else {
            throw SimpleFINError.invalidAccessKey
        }

        var queryItems: [URLQueryItem] = []
        if let startDate {
            queryItems.append(URLQueryItem(
                name: "start-date",
                value: String(SimpleFINAmount.timestamp(fromDay: startDate))
            ))
            // Pending transactions are how a purchase shows up before it
            // posts; they import uncleared and clear on a later sync.
            queryItems.append(URLQueryItem(name: "pending", value: "1"))
        } else {
            queryItems.append(URLQueryItem(name: "balances-only", value: "1"))
        }
        queryItems += accountIds.map { URLQueryItem(name: "account", value: $0) }
        components.queryItems = queryItems

        guard let url = components.url, let authorization = accessKey.basicAuthHeader else {
            throw SimpleFINError.invalidAccessKey
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimpleFINError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw SimpleFINError.forbidden
        }
        guard httpResponse.statusCode == 200 else {
            throw SimpleFINError.httpError(statusCode: httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(SimpleFINAccountSet.self, from: data)
        } catch {
            logger.error("Couldn't decode the SimpleFIN account set: \(error.localizedDescription, privacy: .public)")
            throw SimpleFINError.invalidResponse
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Cancellation is ordinary control flow (a screen the user left).
            throw urlError
        } catch {
            throw SimpleFINError.networkError(error.localizedDescription)
        }
    }
}
