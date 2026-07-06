import Foundation

enum ActualServerError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, message: String?)
    case unauthorized
    case networkError(Error)
    case decodingError(Error)
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code, let message):
            return "HTTP error \(code): \(message ?? "Unknown error")"
        case .unauthorized:
            return "Unauthorized - please log in again"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .fileNotFound:
            return "Budget file not found"
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
    private var token: String?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Configuration

    func configure(serverURL: String) throws {
        guard let url = URL(string: serverURL) else {
            throw ActualServerError.invalidURL
        }
        self.serverURL = url
    }

    func setToken(_ token: String?) {
        self.token = token
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
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["password": password]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)

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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        guard let (data, response) = try? await session.data(for: request),
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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        guard let (data, response) = try? await session.data(for: request),
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
        var request = URLRequest(url: url)
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

        let (data, response) = try await session.data(for: request)

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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")

        let (data, response) = try await session.data(for: request)

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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.setValue(fileId, forHTTPHeaderField: "X-ACTUAL-FILE-ID")

        let (data, response) = try await session.data(for: request)

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

    func getFileInfo(fileId: String) async throws -> FileInfoResponse.FileInfo {
        guard let serverURL else {
            throw ActualServerError.invalidURL
        }

        guard let token else {
            throw ActualServerError.unauthorized
        }

        let url = serverURL.appendingPathComponent("/sync/get-user-file-info")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.setValue(fileId, forHTTPHeaderField: "X-ACTUAL-FILE-ID")

        let (data, response) = try await session.data(for: request)

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

    func getKeyInfo(fileId: String) async throws -> ServerKeyInfo {
        guard let serverURL else { throw ActualServerError.invalidURL }
        guard let token else { throw ActualServerError.unauthorized }

        let url = serverURL.appendingPathComponent("/sync/user-get-key")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.httpBody = try JSONEncoder().encode(["token": token, "fileId": fileId])

        let (data, response) = try await session.data(for: request)
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

    // MARK: - Sync

    func postSync(_ requestData: Data) async throws -> Data {
        guard let serverURL else {
            throw ActualServerError.invalidURL
        }

        guard let token else {
            throw ActualServerError.unauthorized
        }

        let url = serverURL.appendingPathComponent("/sync/sync")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.setValue("application/actual-sync", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestData

        let (data, response) = try await session.data(for: request)

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
