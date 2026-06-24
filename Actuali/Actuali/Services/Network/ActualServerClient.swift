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
