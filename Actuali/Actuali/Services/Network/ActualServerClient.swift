import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "ServerNetwork")

enum ActualServerError: LocalizedError {
    case invalidURL
    case invalidFallbackURL
    case invalidResponse
    case httpError(statusCode: Int, message: String?)
    case unauthorized
    case networkError(any Error)
    case decodingError(any Error)
    case fileNotFound
    case authProxyBlocked

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid server URL")
        case .invalidFallbackURL:
            return String(localized: "Invalid fallback server URL")
        case .invalidResponse:
            return String(localized: "Invalid response from server")
        case .authProxyBlocked:
            return String(localized: "The server responded with a login page instead of data — it looks like it's behind an authentication proxy (e.g. Cloudflare Access). Add the proxy's credentials under Custom HTTP headers, then try again.")
        case .httpError(let code, let message):
            let fallbackMessage = message ?? String(localized: "Unknown error")
            return String(format: String(localized: "HTTP error %lld: %@"), Int64(code), fallbackMessage)
        case .unauthorized:
            return String(localized: "Unauthorized - please log in again")
        case .networkError(let error):
            return Self.connectionFailureMessage(for: error)
        case .decodingError(let error):
            return String(localized: "Failed to decode response: \(error.localizedDescription)")
        case .fileNotFound:
            return String(localized: "Budget file not found")
        }
    }

    /// Whether the server couldn't be reached at all, as opposed to answering
    /// with something unusable. Callers that fall back to a degraded mode on
    /// failure use this to tell "old server" apart from "no server".
    var isConnectionFailure: Bool {
        if case .networkError = self { return true }
        return false
    }

    /// Where the troubleshooting steps for each of these live.
    private static let helpLink = "actuali.mfazz.com/support"

    /// Turns a transport failure into something a non-technical user can act
    /// on. Left to itself, CFNetwork surfaces strings like "TLS Error caused
    /// the secure connection to fail" or a bare `NSURLErrorDomain error -1200`,
    /// which tell the user nothing about what to change.
    static func connectionFailureMessage(for error: any Error) -> String {
        guard let urlError = error as? URLError else {
            return String(localized: "Couldn't connect to your server: \(error.localizedDescription) See \(helpLink) for help.")
        }

        switch urlError.code {
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
            return String(format: String(localized: "Couldn't make a secure connection to your server — iOS doesn't trust its security certificate. This usually means the server is using its own self-signed certificate. See %@ for how to fix it."), helpLink)
        case .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return String(format: String(localized: "Your server's security certificate has expired, so iOS blocked the connection. Renewing the certificate on the server will fix this. See %@ for help."), helpLink)
        case .appTransportSecurityRequiresSecureConnection:
            return String(format: String(localized: "Actuali can only connect over a secure address. Check that your server URL starts with https:// — see %@ for help."), helpLink)
        case .cannotFindHost, .dnsLookupFailed:
            return String(format: String(localized: "Couldn't find a server at that address. Check the server URL for typos. See %@ for help."), helpLink)
        case .cannotConnectToHost:
            return String(format: String(localized: "Couldn't reach your server. If it's only available on your home network, connect to that network and try again. See %@ for help."), helpLink)
        case .notConnectedToInternet:
            return String(localized: "Your device isn't connected to the internet.")
        case .timedOut:
            return String(format: String(localized: "Your server took too long to respond. It may be offline, or blocked on this network. See %@ for help."), helpLink)
        default:
            return String(format: String(localized: "Couldn't connect to your server: %@ See %@ for help."), urlError.localizedDescription, helpLink)
        }
    }
}

struct LoginResponse: Codable, Sendable {
    let status: String
    let data: LoginData?
    let reason: String?

    struct LoginData: Codable, Sendable {
        let token: String
    }
}

/// A login method advertised by `GET /account/login-methods`, e.g. `password` or `openid`.
struct LoginMethod: Codable, Sendable, Equatable {
    let method: String
    let displayName: String?
    /// SQLite stores this as 0/1; decode tolerantly as an integer.
    let active: Int?

    var isActive: Bool { (active ?? 0) != 0 }
}

struct LoginMethodsResponse: Codable, Sendable {
    let status: String
    let methods: [LoginMethod]?
}

/// Response from `POST /account/login` when `loginMethod == "openid"`. The server
/// returns the OpenID provider authorization URL under `data.returnUrl` (not a token).
struct OpenIDInitResponse: Codable, Sendable {
    let status: String
    let data: OpenIDInitData?
    let reason: String?

    struct OpenIDInitData: Codable, Sendable {
        let returnUrl: String
    }
}

struct ListFilesResponse: Codable, Sendable {
    let status: String
    let data: [RemoteFile]?

    struct RemoteFile: Codable, Sendable {
        let fileId: String
        let groupId: String?
        let name: String
        let deleted: Int
        let encryptKeyId: String?
    }
}

struct FileInfoResponse: Codable, Sendable {
    let status: String
    let data: FileInfo?

    struct FileInfo: Codable, Sendable {
        let fileId: String
        let groupId: String?
        let name: String
        let deleted: Int
        let encryptMeta: EncryptMeta?
    }

    struct EncryptMeta: Codable, Sendable {
        let keyId: String
        let algorithm: String?
        let iv: String?
        let authTag: String?
    }
}

struct KeyInfoResponse: Codable, Sendable {
    let status: String
    let data: KeyData?

    struct KeyData: Codable, Sendable {
        let id: String
        let salt: String
        let test: String?
    }
}

// MARK: - Bank sync (server-hosted SimpleFIN)

/// An error the `/simplefin/*` routes report. They answer HTTP 200 and put
/// the failure in `data`, so a status-code check alone never sees these.
struct ServerBankSyncError: Decodable, Sendable, Equatable {
    let errorType: String?
    let errorCode: String?
    let reason: String?

    /// Actual's `bank_sync_status` vocabulary for this failure — the same
    /// mapping upstream's `getBankSyncStatusFromError` applies, so an account
    /// this device failed to sync reads the same in the web UI.
    var bankSyncStatus: String {
        switch errorCode {
        case "ITEM_LOGIN_REQUIRED", "INVALID_ACCESS_TOKEN": return "reauth-required"
        case "ACCOUNT_NEEDS_ATTENTION": return "attention-required"
        case "RATE_LIMIT_EXCEEDED": return "rate-limit-exceeded"
        case "TIMED_OUT": return "timed-out"
        case "ACCOUNT_MISSING": return "account-missing"
        default: return "failed"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case errorType = "error_type"
        case errorCode = "error_code"
        case reason
    }
}

/// One account's slice of a `/simplefin/transactions` response.
struct ServerBankSyncAccountDownload: Decodable, Sendable {
    /// The account's balance *as of now*, in cents, despite the name — see
    /// upstream `processBankSyncDownload`, which calls the same field
    /// "actually the current balance".
    let startingBalance: Int?
    let transactions: Transactions?

    struct Transactions: Decodable, Sendable {
        let all: [ServerBankSyncTransaction]?
    }
}

/// The server's already-normalized transaction shape — not raw SimpleFIN.
/// The bridge's own fields have been renamed and its dates turned into
/// `YYYY-MM-DD` strings by the time they reach us.
struct ServerBankSyncTransaction: Decodable, Sendable {
    let transactionId: String?
    let date: String?
    let payeeName: String?
    let notes: String?
    let booked: Bool?
    let transactionAmount: Amount?

    struct Amount: Decodable, Sendable {
        let amount: String?
    }
}

/// A whole `/simplefin/transactions` response body. The payload is keyed by
/// account id, with `errors` alongside, so it needs dynamic-key decoding.
struct ServerBankSyncDownloads: Decodable, Sendable {
    var accounts: [String: ServerBankSyncAccountDownload] = [:]
    var errors: [String: [ServerBankSyncError]] = [:]
    /// Set when the request failed as a whole (a rejected access key, say),
    /// in which case `data` *is* the error object rather than containing one.
    var failure: ServerBankSyncError?

    init(from decoder: any Decoder) throws {
        // A whole-request failure decodes cleanly here too — every field is
        // optional — so it only counts as one when it names a code.
        let possibleFailure = try? ServerBankSyncError(from: decoder)
        failure = possibleFailure?.errorCode == nil ? nil : possibleFailure

        let container = try decoder.container(keyedBy: DynamicKey.self)
        for key in container.allKeys {
            switch key.stringValue {
            case "errors":
                errors = (try? container.decode([String: [ServerBankSyncError]].self, forKey: key)) ?? [:]
            case "error_type", "error_code", "reason", "status":
                continue
            default:
                // An account the bridge didn't return comes back as null, and
                // decoding it simply doesn't contribute an entry.
                if let download = try? container.decode(
                    ServerBankSyncAccountDownload.self, forKey: key
                ) {
                    accounts[key.stringValue] = download
                }
            }
        }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}


/// Version gate for features that depend on the server's Actual release.
enum ServerVersion {
    /// payee_locations shipped in Actual 26.4.0. Writing those CRDT messages
    /// against an older server breaks its web client with invalid-schema
    /// sync errors, so suppress writes unless we know the server is new
    /// enough. Reads of already-synced rows are always safe.
    static func supportsPayeeLocations(_ version: String?) -> Bool {
        guard let version else { return false }
        let parts = version.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, let major = parts[0], let minor = parts[1] else {
            return false
        }
        return major > 26 || (major == 26 && minor >= 4)
    }
}

actor ActualServerClient {
    private let session: URLSession
    private var serverURL: URL?
    private var fallbackServerURL: URL?
    /// The primary as the user configured it, unaffected by failover swaps,
    /// so a recovery probe knows which address to check.
    private var configuredPrimaryURL: URL?
    private var token: String?

    /// User-supplied headers stamped onto every outgoing request, in order.
    /// Used to authenticate through reverse-proxy layers that sit in front of
    /// the Actual server (e.g. Cloudflare Access service tokens). Applied
    /// before the client's own headers so app headers like `X-ACTUAL-TOKEN`
    /// always take precedence.
    private var customHeaders: [(name: String, value: String)] = []

    /// - Parameter session: overridable so tests can drive the client through a
    ///   stub transport; production callers take the default.
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Configuration

    func configure(serverURL: String, fallbackServerURL: String = "") throws {
        guard let url = URL(string: serverURL) else {
            throw ActualServerError.invalidURL
        }
        // Set the primary before validating the fallback: configureSavedSession
        // swallows this method's errors with try?, and a bad fallback must not
        // leave the client without a working primary.
        self.serverURL = url
        self.configuredPrimaryURL = url
        self.fallbackServerURL = nil
        if !fallbackServerURL.isEmpty {
            guard let fallbackURL = URL(string: fallbackServerURL),
                  fallbackURL.scheme != nil,
                  fallbackURL.host != nil else {
                throw ActualServerError.invalidFallbackURL
            }
            self.fallbackServerURL = fallbackURL
        }
    }

    func setToken(_ token: String?) {
        self.token = token
    }

    func setCustomHeaders(_ headers: [(name: String, value: String)]) {
        self.customHeaders = headers
    }

    /// Build a request with the user's custom headers already applied. Callers
    /// then set method-specific headers (which override any same-named custom
    /// header) and the body.
    private func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        for header in customHeaders {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return request
    }

    /// Perform a request, translating transport failures into
    /// `ActualServerError.networkError` so callers surface actionable guidance
    /// instead of CFNetwork's raw description.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        // Capture both bases that apply to this request before suspension. Another
        // request may swap them on the actor while this one is awaiting its response.
        let requestServerURL = serverURL
        let requestFallbackURL = fallbackServerURL
        do {
            return try await session.data(for: request)
        } catch let urlError as URLError where urlError.code != .cancelled {
            if let requestFallbackURL,
               let requestURL = request.url,
               let primaryServerURL = requestServerURL,
               requestURL.host == primaryServerURL.host,
               urlError.code != .notConnectedToInternet,
               let fallbackURL = Self.fallbackRequestURL(
                   requestURL: requestURL,
                   primaryServerURL: primaryServerURL,
                   fallbackServerURL: requestFallbackURL
               ),
               fallbackURL != requestURL {
                var fallbackRequest = request
                fallbackRequest.url = fallbackURL
                do {
                    let result = try await session.data(for: fallbackRequest)
                    // Stick with the address that answered: swap the roles so
                    // subsequent requests skip the dead address's timeout. A
                    // later failure retries the old primary through this same
                    // path, so a recovered primary swaps straight back.
                    if serverURL == requestServerURL {
                        serverURL = requestFallbackURL
                        fallbackServerURL = requestServerURL
                    }
                    logger.notice(
                        "Server was unreachable; switched to the configured alternate address"
                    )
                    return result
                } catch let fallbackError as URLError where fallbackError.code != .cancelled {
                    logger.error(
                        "Fallback address also failed: \(fallbackError.code.rawValue, privacy: .public)"
                    )
                    // The primary is the address the user thinks of as "the
                    // server", so its error is the one that tells them what
                    // to fix; the fallback's failure lives in the log above.
                    throw ActualServerError.networkError(urlError)
                }
            }
            // Cancellation is ordinary control flow (a superseded refresh, a
            // screen the user left), so it propagates untouched.
            throw ActualServerError.networkError(urlError)
        }
    }

    /// After a failover, check whether the configured primary is reachable
    /// again and swap back if so. Safe to fire-and-forget on foreground: the
    /// short probe timeout never blocks callers' own requests, and a no-op
    /// when the session is already on the primary.
    func retryPrimaryIfRecovered() async {
        guard let configuredPrimaryURL,
              let current = serverURL,
              current != configuredPrimaryURL else { return }
        var request = makeRequest(configuredPrimaryURL.appendingPathComponent("/info"))
        request.timeoutInterval = 5
        // Older servers and route-stripping reverse proxies don't answer
        // /info (see fetchServerVersion), so any client-side status proves
        // the primary is reachable; 5xx means a proxy whose backend is down,
        // so stay on the fallback.
        guard let (_, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode,
              (200..<500).contains(status) else { return }
        // Re-check after the await: a concurrent request may have swapped.
        if serverURL == current {
            fallbackServerURL = current
            serverURL = configuredPrimaryURL
            logger.notice("Primary server is reachable again; switched back to it")
        }
    }

    /// Rebase an API request from the primary server onto the fallback while
    /// preserving path prefixes on either address (for example `/actual`).
    private static func fallbackRequestURL(
        requestURL: URL,
        primaryServerURL: URL,
        fallbackServerURL: URL
    ) -> URL? {
        let primaryPath = primaryServerURL.path(percentEncoded: true)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestPath = requestURL.path(percentEncoded: true)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath: Substring
        if !primaryPath.isEmpty,
           requestPath == primaryPath || requestPath.hasPrefix(primaryPath + "/") {
            endpointPath = requestPath.dropFirst(primaryPath.count)
        } else {
            endpointPath = requestPath[...]
        }

        var components = URLComponents(
            url: fallbackServerURL,
            resolvingAgainstBaseURL: false
        )
        let fallbackPath = fallbackServerURL.path(percentEncoded: true)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = String(endpointPath)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.percentEncodedPath = "/" + [fallbackPath, endpoint]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components?.percentEncodedQuery = URLComponents(
            url: requestURL,
            resolvingAgainstBaseURL: false
        )?.percentEncodedQuery
        return components?.url
    }

    /// Whether a response looks like an auth proxy's login page rather than the
    /// Actual server's JSON. Reverse proxies (Cloudflare Access, Authelia, etc.)
    /// intercept unauthenticated requests and return an HTML login page, which
    /// otherwise surfaces as a cryptic JSON decoding error. Detected by a
    /// non-JSON `Content-Type` or a redirect landing on a known Access host.
    private func looksLikeAuthProxy(_ response: HTTPURLResponse, data: Data) -> Bool {
        if let host = response.url?.host?.lowercased(),
           host.contains("cloudflareaccess.com") {
            return true
        }
        guard let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() else {
            return false
        }
        // The Actual API always answers with JSON; HTML means we hit a proxy.
        return contentType.contains("text/html") && !data.isEmpty
    }

    var isConfigured: Bool {
        serverURL != nil
    }

    var isAuthenticated: Bool {
        token != nil
    }

    // MARK: - Authentication

    func login(password: String) async throws -> String {
        guard let serverURL else {
            throw ActualServerError.invalidURL
        }

        let url = serverURL.appendingPathComponent("/account/login")
        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["password": password]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await send(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualServerError.invalidResponse
        }

        if httpResponse.statusCode == 400 {
            throw ActualServerError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)
            throw ActualServerError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        if looksLikeAuthProxy(httpResponse, data: data) {
            throw ActualServerError.authProxyBlocked
        }

        let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)

        guard loginResponse.status == "ok", let token = loginResponse.data?.token else {
            throw ActualServerError.unauthorized
        }

        self.token = token
        return token
    }

    /// Discover which login methods the server supports (`password`, `openid`, …)
    /// via `GET /account/login-methods`. Unauthenticated. Returns every method
    /// the server reports, including inactive ones (each carries its own
    /// `active` flag) — callers need to know a password fallback *exists* even
    /// when it isn't the active method, because the first OpenID sign-in may
    /// require it. Older servers without this endpoint (404) are treated as
    /// password-only, which is the safe default.
    func fetchLoginMethods() async throws -> [LoginMethod] {
        guard let serverURL else {
            throw ActualServerError.invalidURL
        }

        let url = serverURL.appendingPathComponent("/account/login-methods")
        var request = makeRequest(url)
        request.httpMethod = "GET"

        let (data, response) = try await send(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualServerError.invalidResponse
        }

        // Servers predating the login-methods endpoint only do password auth.
        if httpResponse.statusCode == 404 {
            return [LoginMethod(method: "password", displayName: "Password", active: 1)]
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)
            throw ActualServerError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        if looksLikeAuthProxy(httpResponse, data: data) {
            throw ActualServerError.authProxyBlocked
        }

        let decoded = try JSONDecoder().decode(LoginMethodsResponse.self, from: data)
        guard decoded.status == "ok", let methods = decoded.methods else {
            throw ActualServerError.invalidResponse
        }
        return methods
    }

    /// Whether an account owner has been created yet (`GET /admin/owner-created/`,
    /// which returns a bare JSON boolean). When this is `false` and the server
    /// has a password fallback, the first OpenID sign-in must supply the server
    /// password. Defaults to `true` on any failure so we don't nag the user on
    /// servers where the endpoint is unavailable.
    func fetchOwnerCreated() async -> Bool {
        guard let serverURL else { return true }
        let url = serverURL.appendingPathComponent("/admin/owner-created/")
        var request = makeRequest(url)
        request.httpMethod = "GET"

        guard let (data, response) = try? await send(request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let created = try? JSONDecoder().decode(Bool.self, from: data) else {
            return true
        }
        return created
    }

    private struct ServerInfoResponse: Decodable {
        struct Build: Decodable {
            let version: String?
        }
        let build: Build?
    }

    /// `GET /info` — the sync server's build metadata. Returns nil on any
    /// failure (older servers, reverse proxies stripping the route, etc.);
    /// callers treat nil as "capabilities unknown".
    func fetchServerVersion() async -> String? {
        guard let serverURL else { return nil }
        let url = serverURL.appendingPathComponent("/info")
        var request = makeRequest(url)
        request.httpMethod = "GET"

        guard let (data, response) = try? await send(request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let info = try? JSONDecoder().decode(ServerInfoResponse.self, from: data) else {
            return nil
        }
        return info.build?.version
    }

    /// Begin an OpenID login by POSTing to `/account/login` with
    /// `loginMethod = "openid"`. The server validates `returnURL` (its hostname
    /// must match the server or be `localhost`), stores a pending request, and
    /// returns the OpenID provider's authorization URL to open in a browser.
    ///
    /// - Parameters:
    ///   - returnURL: where the server should redirect after the OP callback.
    ///     Use a custom-scheme URL whose host is `localhost` (e.g.
    ///     `actuali://localhost`) so it passes the server's redirect check and
    ///     can be intercepted by `ASWebAuthenticationSession`.
    ///   - firstTimePassword: required only when the server also has password
    ///     auth configured and no named users exist yet (first login).
    /// - Returns: the authorization URL to present to the user.
    func beginOpenIDLogin(returnURL: String, firstTimePassword: String?) async throws -> URL {
        guard let serverURL else {
            throw ActualServerError.invalidURL
        }

        let url = serverURL.appendingPathComponent("/account/login")
        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [
            "loginMethod": "openid",
            "returnUrl": returnURL
        ]
        if let firstTimePassword, !firstTimePassword.isEmpty {
            body["password"] = firstTimePassword
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await send(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualServerError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            // Surface the server's `reason` (e.g. invalid-password, invalid-return-url) when present.
            let reason = (try? JSONDecoder().decode(OpenIDInitResponse.self, from: data))?.reason
            throw ActualServerError.httpError(
                statusCode: httpResponse.statusCode,
                message: reason ?? String(data: data, encoding: .utf8)
            )
        }

        let decoded = try JSONDecoder().decode(OpenIDInitResponse.self, from: data)
        guard decoded.status == "ok",
              let urlString = decoded.data?.returnUrl,
              let authURL = URL(string: urlString) else {
            throw ActualServerError.invalidResponse
        }
        return authURL
    }

    // MARK: - Files

    func listFiles() async throws -> [ListFilesResponse.RemoteFile] {
        guard let serverURL else {
            throw ActualServerError.invalidURL
        }

        guard let token else {
            throw ActualServerError.unauthorized
        }

        let url = serverURL.appendingPathComponent("/sync/list-user-files")
        var request = makeRequest(url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")

        let (data, response) = try await send(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualServerError.invalidResponse
        }

        if httpResponse.statusCode == 403 {
            throw ActualServerError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)
            throw ActualServerError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        let listResponse = try JSONDecoder().decode(ListFilesResponse.self, from: data)

        guard listResponse.status == "ok", let files = listResponse.data else {
            throw ActualServerError.invalidResponse
        }

        // Filter out deleted files
        return files.filter { $0.deleted == 0 }
    }

    func downloadFile(fileId: String) async throws -> Data {
        guard let serverURL else {
            throw ActualServerError.invalidURL
        }

        guard let token else {
            throw ActualServerError.unauthorized
        }

        let url = serverURL.appendingPathComponent("/sync/download-user-file")
        var request = makeRequest(url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.setValue(fileId, forHTTPHeaderField: "X-ACTUAL-FILE-ID")

        let (data, response) = try await send(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualServerError.invalidResponse
        }

        if httpResponse.statusCode == 403 {
            throw ActualServerError.unauthorized
        }

        if httpResponse.statusCode == 400 || httpResponse.statusCode == 404 {
            throw ActualServerError.fileNotFound
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)
            throw ActualServerError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        return data
    }

    /// Upload a budget archive to `/sync/upload-user-file`, registering it on
    /// the server. Returns the sync group id the server assigned (a fresh one
    /// when no `X-ACTUAL-GROUP-ID` is sent, as for a newly created file).
    /// Mirrors upstream's upload (loot-core cloud-storage.ts:289) minus the
    /// encryption branch — Actuali only creates unencrypted files.
    func uploadFile(zipData: Data, fileId: String, name: String) async throws -> String {
        guard let serverURL else {
            throw ActualServerError.invalidURL
        }

        guard let token else {
            throw ActualServerError.unauthorized
        }

        let url = serverURL.appendingPathComponent("/sync/upload-user-file")
        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.setValue(fileId, forHTTPHeaderField: "X-ACTUAL-FILE-ID")
        // Upstream sends encodeURIComponent(budgetName), whose unreserved set
        // is exactly this (ASCII only — CharacterSet.alphanumerics would leave
        // non-ASCII letters unescaped and produce an invalid header value).
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
        )
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name
        request.setValue(encodedName, forHTTPHeaderField: "X-ACTUAL-NAME")
        request.setValue("2", forHTTPHeaderField: "X-ACTUAL-FORMAT")
        request.setValue("application/encrypted-file", forHTTPHeaderField: "Content-Type")
        request.httpBody = zipData

        let (data, response) = try await send(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualServerError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw ActualServerError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)
            throw ActualServerError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        struct UploadResponse: Decodable {
            let status: String
            let groupId: String?
        }
        let decoded = try JSONDecoder().decode(UploadResponse.self, from: data)
        guard decoded.status == "ok", let groupId = decoded.groupId else {
            throw ActualServerError.invalidResponse
        }
        return groupId
    }

    func getFileInfo(fileId: String) async throws -> FileInfoResponse.FileInfo {
        guard let serverURL else {
            throw ActualServerError.invalidURL
        }

        guard let token else {
            throw ActualServerError.unauthorized
        }

        let url = serverURL.appendingPathComponent("/sync/get-user-file-info")
        var request = makeRequest(url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.setValue(fileId, forHTTPHeaderField: "X-ACTUAL-FILE-ID")

        let (data, response) = try await send(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualServerError.invalidResponse
        }

        if httpResponse.statusCode == 403 {
            throw ActualServerError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)
            throw ActualServerError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        let infoResponse = try JSONDecoder().decode(FileInfoResponse.self, from: data)

        guard infoResponse.status == "ok", let fileInfo = infoResponse.data else {
            throw ActualServerError.fileNotFound
        }

        return fileInfo
    }

    /// `POST /sync/delete-user-file` — marks the file deleted on the server for
    /// every client. Mirrors upstream's `removeFile` (cloud-storage.ts), which
    /// sends the token in the body; the header is our usual transport for it.
    func deleteFile(fileId: String) async throws {
        guard let serverURL else { throw ActualServerError.invalidURL }
        guard let token else { throw ActualServerError.unauthorized }

        let url = serverURL.appendingPathComponent("/sync/delete-user-file")
        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.httpBody = try JSONEncoder().encode(["token": token, "fileId": fileId])

        let (data, response) = try await send(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualServerError.invalidResponse
        }
        // Callers treat .fileNotFound as "already deleted" and destroy the
        // local copy, so nothing that isn't the Actual server's own answer may
        // map to it: an auth proxy's login page is named as such, and 404 —
        // which the server never sends for a missing file (it answers 400, its
        // own FIXME notwithstanding) — stays a plain HTTP error, since it
        // usually means a proxy or a stripped route.
        if looksLikeAuthProxy(httpResponse, data: data) {
            throw ActualServerError.authProxyBlocked
        }
        if httpResponse.statusCode == 403 { throw ActualServerError.unauthorized }
        if httpResponse.statusCode == 400, data == Data("file-not-found".utf8) {
            throw ActualServerError.fileNotFound
        }
        guard httpResponse.statusCode == 200 else {
            throw ActualServerError.httpError(
                statusCode: httpResponse.statusCode, message: String(data: data, encoding: .utf8)
            )
        }
    }

    func getKeyInfo(fileId: String) async throws -> ServerKeyInfo {
        guard let serverURL else { throw ActualServerError.invalidURL }
        guard let token else { throw ActualServerError.unauthorized }

        let url = serverURL.appendingPathComponent("/sync/user-get-key")
        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.httpBody = try JSONEncoder().encode(["token": token, "fileId": fileId])

        let (data, response) = try await send(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualServerError.invalidResponse
        }
        if httpResponse.statusCode == 403 { throw ActualServerError.unauthorized }
        guard httpResponse.statusCode == 200 else {
            throw ActualServerError.httpError(statusCode: httpResponse.statusCode, message: String(data: data, encoding: .utf8))
        }

        let decoded = try JSONDecoder().decode(KeyInfoResponse.self, from: data)
        guard decoded.status == "ok", let key = decoded.data else {
            throw ActualServerError.invalidResponse
        }
        return ServerKeyInfo(id: key.id, salt: key.salt, test: key.test)
    }

    // MARK: - Bank sync (server-hosted SimpleFIN)

    /// Whether the server has its own SimpleFIN credentials, or nil when it
    /// has no `/simplefin` routes at all (an Actual release that predates
    /// them, or a reverse proxy that strips them). Callers treat nil as "this
    /// server can't do bank sync" and fall back to the device's own key —
    /// which is why a route that isn't there and a server that can't be
    /// reached must not look the same: the latter throws.
    func simpleFINStatus() async throws -> Bool? {
        let response: SimpleFINStatusResponse? = try await postBankSync(
            path: "/simplefin/status", body: EmptyBody()
        )
        return response?.data?.configured
    }

    /// Every account the server's SimpleFIN connection covers, in the raw
    /// bridge shape (the route passes it through untouched).
    func simpleFINAccounts() async throws -> [SimpleFINAccount] {
        guard let response: SimpleFINServerAccountsResponse = try await postBankSync(
            path: "/simplefin/accounts", body: EmptyBody()
        ) else {
            throw ActualServerError.invalidResponse
        }
        if let failure = response.data?.failure {
            throw ActualServerError.httpError(
                statusCode: 200, message: failure.reason ?? failure.errorCode
            )
        }
        return response.data?.accounts ?? []
    }

    /// Transactions for the named accounts, each from its own start date.
    /// - Parameters:
    ///   - accountIds: the provider's account ids (`accounts.account_id`).
    ///   - startDates: `YYYY-MM-DD`, one per account id and the same length —
    ///     the route rejects a mismatch.
    func simpleFINTransactions(
        accountIds: [String],
        startDates: [String]
    ) async throws -> ServerBankSyncDownloads {
        guard accountIds.count == startDates.count else {
            throw ActualServerError.invalidResponse
        }
        // Always the array form, even for one account: it keeps the response
        // shape the same, and the single-account form buries an error where
        // the account's data would be.
        let body = SimpleFINTransactionsRequest(accountId: accountIds, startDate: startDates)
        guard let response: SimpleFINTransactionsResponse = try await postBankSync(
            path: "/simplefin/transactions", body: body
        ) else {
            throw ActualServerError.invalidResponse
        }
        guard let data = response.data else { throw ActualServerError.invalidResponse }
        return data
    }

    private struct EmptyBody: Encodable {}

    private struct SimpleFINTransactionsRequest: Encodable {
        let accountId: [String]
        let startDate: [String]
    }

    private struct SimpleFINStatusResponse: Decodable {
        let data: StatusData?
        struct StatusData: Decodable { let configured: Bool? }
    }

    private struct SimpleFINServerAccountsResponse: Decodable {
        let data: AccountsData?

        struct AccountsData: Decodable {
            let accounts: [SimpleFINAccount]?
            let failure: ServerBankSyncError?

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                accounts = try? container.decodeIfPresent([SimpleFINAccount].self, forKey: .accounts)
                let possibleFailure = try? ServerBankSyncError(from: decoder)
                failure = possibleFailure?.errorCode == nil ? nil : possibleFailure
            }

            private enum CodingKeys: String, CodingKey { case accounts }
        }
    }

    private struct SimpleFINTransactionsResponse: Decodable {
        let data: ServerBankSyncDownloads?
    }

    /// Shared plumbing for the `/simplefin` routes. Returns nil when the route
    /// isn't there; throws for everything else.
    private func postBankSync<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body
    ) async throws -> Response? {
        guard let serverURL else { throw ActualServerError.invalidURL }
        guard let token else { throw ActualServerError.unauthorized }

        var request = makeRequest(serverURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await send(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualServerError.invalidResponse
        }
        if httpResponse.statusCode == 403 { throw ActualServerError.unauthorized }
        // The route genuinely isn't served here — not a failure, just an older
        // server. 501 covers proxies that answer unimplemented paths that way.
        if [404, 405, 501].contains(httpResponse.statusCode) { return nil }
        guard httpResponse.statusCode == 200 else {
            throw ActualServerError.httpError(
                statusCode: httpResponse.statusCode, message: String(data: data, encoding: .utf8)
            )
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ActualServerError.decodingError(error)
        }
    }


    // MARK: - Sync

    func postSync(_ requestData: Data) async throws -> Data {
        guard let serverURL else {
            throw ActualServerError.invalidURL
        }

        guard let token else {
            throw ActualServerError.unauthorized
        }

        let url = serverURL.appendingPathComponent("/sync/sync")
        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.setValue("application/actual-sync", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestData

        let (data, response) = try await send(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualServerError.invalidResponse
        }

        if httpResponse.statusCode == 403 {
            throw ActualServerError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)
            throw ActualServerError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        return data
    }
}
